package com.mawena.fluluks.ai.auto

import androidx.annotation.VisibleForTesting
import com.mawena.fluluks.ai.AiException
import com.mawena.fluluks.ai.AiProvider
import com.mawena.fluluks.ai.AiServerConfig
import com.mawena.fluluks.ai.ChatEvent
import com.mawena.fluluks.ai.ChatMessage
import com.mawena.fluluks.ai.ChatRequest
import com.mawena.fluluks.ai.DeltaPump
import com.mawena.fluluks.ai.chat.ChatSessions
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException
import java.time.LocalDateTime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** Variable d'un modèle de prompt et sa valeur par défaut (obligatoire pour une exécution planifiée). */
data class AutomationVar(val name: String, val default: String?)

/** Planification des exécutions (WorkManager dans l'application, simulée dans les tests). */
interface AutomationScheduler {
    /** Exécution toutes les `intervalMinutes` minutes, réseau requis ; remplace la planification précédente. */
    fun schedule(a: Automation)

    fun cancel(automationId: Long)
}

/** Destinataire d'un lancement manuel (le pont vers Dart) : texte reçu par lots, puis l'exécution terminée. */
interface AutomationSink {
    fun delta(runId: Long, text: String, delivered: () -> Unit)

    fun state(r: AutomationRun)
}

/**
 * Exécution planifiée : [run] écrite (null si l'automatisation n'existe plus ou n'est plus planifiée, sa planification
 * étant alors annulée) ; [retry] : un délai ou une erreur 5xx au premier essai, que WorkManager peut reprendre une fois.
 */
data class ScheduledOutcome(val automation: Automation?, val run: AutomationRun?, val retry: Boolean)

/**
 * Automatisations (phase 15, T8, spec § 23) : modèles de prompt à variables, lancés à la main (résultat suivi en direct,
 * par lots vers [sink], comme les réponses du chat) ou planifiés (réponse entière, sans flux). [MAX_AUTOMATIONS] au
 * plus ; planification toutes les [MIN_INTERVAL] minutes au moins, annulée quand l'automatisation est désactivée,
 * supprimée, rendue manuelle, ou que son serveur est supprimé ; [MAX_RUNS] dernières exécutions gardées par
 * automatisation. Un échec est noté avec sa raison ; seuls un délai ou une erreur 5xx sont repris, une fois. Ni prompt
 * ni résultat dans un journal. Appelé hors du fil principal.
 */
class Automations(
    private val dao: AutomationDao,
    private val servers: () -> List<AiServerConfig>,
    private val providerFor: (serverId: String) -> AiProvider,
    private val scheduler: AutomationScheduler,
    private val tx: (() -> Unit) -> Unit,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val now: () -> Long = System::currentTimeMillis,
    private val clock: () -> LocalDateTime = LocalDateTime::now,
    private val batchMs: Long = ChatSessions.BATCH_MS,
    private val maxBatch: Int = ChatSessions.MAX_BATCH,
    private val maxInflight: Int = ChatSessions.MAX_INFLIGHT,
    private val ackTimeoutMs: Long = ChatSessions.ACK_TIMEOUT_MS,
) {
    /** Le pont, quand Dart est là ; sans lui, les lots ne partent pas (le résultat reste dans l'exécution). */
    @Volatile var sink: AutomationSink? = null

    /** Lancements manuels en cours : exécution → (automatisation, travail). */
    private val jobs = HashMap<Long, Pair<Long, Job>>()

    fun list(): List<Automation> = dao.automations()

    /** [FilesException] FL_ENOENT si elle a été supprimée. */
    fun get(id: Long): Automation = dao.automation(id) ?: throw FilesException(EngineError.FL_ENOENT, MSG_GONE)

    fun variablesOf(a: Automation): List<AutomationVar> = decodeVars(a.variables)

    /**
     * Enregistre [a] ([a].id 0 : nouvelle) avec les valeurs par défaut de [vars] ; seules les variables du modèle sont
     * gardées, dans leur ordre. Sans serveur : serveur par défaut ; sans modèle : modèle par défaut du serveur. Planifie
     * ou annule selon le déclencheur. [FilesException] FL_EINVAL (fiche invalide), FL_ENOSPC (trop d'automatisations).
     */
    fun save(a: Automation, vars: List<AutomationVar>): Automation {
        val name = a.name.trim()
        if (name.isEmpty()) throw FilesException(EngineError.FL_EINVAL, MSG_NAME)
        if (name.length > MAX_NAME) throw FilesException(EngineError.FL_EINVAL, MSG_NAME_LONG)
        Template.validate(a.template, vars.map { it.name }.toSet())
        val byName = vars.associateBy { it.name }
        val kept = Template.variables(a.template).map { AutomationVar(it, byName[it]?.default?.takeIf { d -> d.isNotEmpty() }) }
        val periodic = a.trigger == Automation.PERIODIC
        if (a.trigger != Automation.MANUAL && !periodic) throw FilesException(EngineError.FL_EINVAL, MSG_TRIGGER)
        if (periodic) {
            val every = a.intervalMinutes ?: 0
            if (every < MIN_INTERVAL) throw FilesException(EngineError.FL_EINVAL, MSG_INTERVAL)
            kept.firstOrNull { it.default == null }?.let {
                throw FilesException(EngineError.FL_EINVAL, "Donnez une valeur par défaut à {{${it.name}}} : une exécution planifiée n'a personne pour la saisir")
            }
        }
        val all = servers()
        val server = if (a.serverId == null) all.firstOrNull { it.isDefault } ?: all.firstOrNull() else all.firstOrNull { it.id == a.serverId }
        val serverId = a.serverId ?: server?.id ?: throw FilesException(EngineError.FL_EINVAL, MSG_NO_SERVER)
        val model = a.model?.trim()?.ifEmpty { null } ?: server?.defaultModel ?: throw FilesException(EngineError.FL_EINVAL, MSG_NO_MODEL)
        val t = now()
        var saved: Automation? = null
        tx {
            val old = if (a.id == 0L) null else get(a.id)
            if (old == null && dao.count() >= MAX_AUTOMATIONS) throw FilesException(EngineError.FL_ENOSPC, MSG_TOO_MANY)
            val clean = a.copy(
                name = name, variables = encodeVars(kept), serverId = serverId, model = model,
                systemPrompt = a.systemPrompt?.trim()?.ifEmpty { null },
                intervalMinutes = if (periodic) a.intervalMinutes else null,
                createdAt = old?.createdAt ?: t, updatedAt = t,
            )
            saved = if (old == null) clean.copy(id = dao.insertAutomation(clean)) else clean.also(dao::updateAutomation)
        }
        return saved!!.also(::plan)
    }

    fun delete(id: Long) {
        scheduler.cancel(id)
        synchronized(jobs) { jobs.values.filter { it.first == id }.map { it.second } }.forEach { it.cancel() }
        tx {
            dao.deleteRuns(id)
            dao.deleteAutomation(id)
        }
    }

    fun setEnabled(id: Long, enabled: Boolean): Automation {
        var out: Automation? = null
        tx { out = get(id).copy(enabled = enabled, updatedAt = now()).also(dao::updateAutomation) }
        return out!!.also(::plan)
    }

    /** Copie désactivée (« Nom (copie) ») : rien n'est planifié avant que l'utilisateur ne l'active. */
    fun duplicate(id: Long): Automation {
        val a = get(id)
        return save(a.copy(id = 0, name = (a.name + COPY_SUFFIX).take(MAX_NAME), enabled = false), variablesOf(a))
    }

    /** Le serveur [serverId] a été supprimé : ses automatisations sont désactivées et leur planification annulée. */
    fun serverDeleted(serverId: String) {
        for (a in dao.automationsOf(serverId)) {
            scheduler.cancel(a.id)
            tx { dao.automation(a.id)?.let { dao.updateAutomation(it.copy(enabled = false, updatedAt = now())) } }
        }
    }

    /** Plus récente d'abord. */
    fun runs(automationId: Long): List<AutomationRun> = dao.runs(automationId)

    fun run(runId: Long): AutomationRun = dao.run(runId) ?: throw FilesException(EngineError.FL_ENOENT, MSG_RUN_GONE)

    fun lastRun(automationId: Long): AutomationRun? = dao.lastRun(automationId)

    fun clearRuns(automationId: Long) = dao.deleteRuns(automationId)

    /** Au démarrage : une exécution restée « en cours » a été coupée par l'arrêt de Portail. */
    fun recoverInterrupted(): Int = dao.markInterrupted(MSG_INTERRUPTED, now())

    /** Exécutions manuelles en cours. */
    fun running(): Set<Long> = synchronized(jobs) { jobs.keys.toSet() }

    @VisibleForTesting
    fun job(runId: Long): Job? = synchronized(jobs) { jobs[runId]?.second }

    /**
     * Lancement manuel : [values] saisies (une variable absente prend sa valeur par défaut) ; l'exécution « en cours »
     * est écrite puis rendue, le résultat arrive par [sink]. FL_EINVAL (valeur manquante), FL_EBUSY (déjà en cours).
     */
    fun start(automationId: Long, values: Map<String, String>): AutomationRun {
        val a = get(automationId)
        val input = render(a, values)
        synchronized(jobs) {
            if (jobs.values.any { it.first == automationId }) throw FilesException(EngineError.FL_EBUSY, MSG_BUSY)
            val run = insertRun(a, input, scheduled = false)
            val job = scope.launch(start = CoroutineStart.LAZY) { stream(a, run) }
            jobs[run.id] = automationId to job
            job.invokeOnCompletion { synchronized(jobs) { if (jobs[run.id]?.second === job) jobs.remove(run.id) } }
            job.start()
            return run
        }
    }

    /** Arrête un lancement manuel : le texte reçu est gardé, état « arrêtée ». */
    fun stop(runId: Long) {
        job(runId)?.cancel()
    }

    /**
     * Exécution planifiée de [automationId] ([attempt] : essai WorkManager, 0 au premier) : valeurs par défaut, réponse
     * entière. Une automatisation supprimée, désactivée ou devenue manuelle n'est pas exécutée et sa planification est
     * annulée.
     */
    suspend fun executeScheduled(automationId: Long, attempt: Int): ScheduledOutcome {
        val a = dao.automation(automationId)
        if (a == null || !a.enabled || a.trigger != Automation.PERIODIC) {
            scheduler.cancel(automationId)
            return ScheduledOutcome(a, null, false)
        }
        val input = try {
            render(a, emptyMap())
        } catch (e: FilesException) {
            val run = insertRun(a, a.template, scheduled = true)
            return ScheduledOutcome(a, finish(run, null, AutomationRun.FAILED, e.message, null), false)
        }
        val run = insertRun(a, input, scheduled = true)
        return try {
            val text = withProvider(a) { p -> p.complete(request(a, input)) }
            ScheduledOutcome(a, finish(run, text, AutomationRun.DONE, null, null), false)
        } catch (e: CancellationException) {
            withContext(NonCancellable) { finish(run, null, AutomationRun.STOPPED, null, null) }
            throw e
        } catch (e: AiException) {
            ScheduledOutcome(a, finish(run, null, AutomationRun.FAILED, e.message, e.serverMessage), e.retryable && attempt == 0)
        } catch (e: FilesException) {
            ScheduledOutcome(a, finish(run, null, AutomationRun.FAILED, e.message, null), false)
        } catch (e: Exception) {
            ScheduledOutcome(a, finish(run, null, AutomationRun.FAILED, ChatSessions.MSG_UNEXPECTED, null), false)
        }
    }

    private fun plan(a: Automation) {
        if (a.enabled && a.trigger == Automation.PERIODIC) scheduler.schedule(a) else scheduler.cancel(a.id)
    }

    private fun render(a: Automation, values: Map<String, String>): String {
        val defaults = variablesOf(a).mapNotNull { v -> v.default?.let { v.name to it } }.toMap()
        return Template.render(a.template, defaults + values.filterValues { it.isNotEmpty() }, clock())
    }

    private fun request(a: Automation, input: String): ChatRequest {
        val model = a.model ?: throw FilesException(EngineError.FL_EINVAL, MSG_NO_MODEL)
        val messages = listOfNotNull(a.systemPrompt?.let { ChatMessage("system", it) }) + ChatMessage("user", input)
        return ChatRequest(model, messages)
    }

    private suspend fun <T> withProvider(a: Automation, block: suspend (AiProvider) -> T): T {
        val serverId = a.serverId ?: throw FilesException(EngineError.FL_ENOENT, MSG_NO_SERVER)
        val p = providerFor(serverId)
        try {
            return block(p)
        } finally {
            (p as? AutoCloseable)?.close()
        }
    }

    private fun insertRun(a: Automation, input: String, scheduled: Boolean): AutomationRun {
        val r = AutomationRun(
            automationId = a.id, startedAt = now(), endedAt = null, state = AutomationRun.RUNNING,
            scheduled = scheduled, input = input, output = null, error = null, errorDetail = null,
        )
        var out: AutomationRun? = null
        tx {
            out = r.copy(id = dao.insertRun(r))
            dao.pruneRuns(a.id, MAX_RUNS)
        }
        return out!!
    }

    private fun finish(run: AutomationRun, output: String?, state: String, error: String?, detail: String?): AutomationRun {
        val done = run.copy(endedAt = now(), state = state, output = output, error = error, errorDetail = detail)
        runCatching { dao.updateRun(done) }
        return done
    }

    private class Outcome(val state: String, val error: String? = null, val detail: String? = null)

    private suspend fun stream(a: Automation, run: AutomationRun) {
        val text = StringBuilder()
        var outcome: Outcome? = null
        val pump = DeltaPump(
            send = { sink?.let { s -> { chunk, delivered -> s.delta(run.id, chunk, delivered) } } },
            batchMs = batchMs,
            maxBatch = maxBatch,
            maxInflight = maxInflight,
            ackTimeoutMs = ackTimeoutMs,
        )
        try {
            withProvider(a) { p ->
                pump.run {
                    p.chat(request(a, run.input)).collect { ev ->
                        when (ev) {
                            is ChatEvent.Delta -> {
                                synchronized(text) { text.append(ev.text) }
                                pump.offer(ev.text)
                            }
                            is ChatEvent.Done -> outcome = Outcome(AutomationRun.DONE)
                            is ChatEvent.Failed -> outcome = Outcome(AutomationRun.FAILED, ev.error.message, ev.error.serverMessage)
                        }
                    }
                }
            }
            if (outcome == null) outcome = Outcome(AutomationRun.FAILED, AiException(AiException.Kind.INTERRUPTED).message)
        } catch (e: CancellationException) {
            if (outcome == null) outcome = Outcome(AutomationRun.STOPPED)
            throw e
        } catch (e: AiException) {
            outcome = Outcome(AutomationRun.FAILED, e.message, e.serverMessage)
        } catch (e: FilesException) {
            outcome = Outcome(AutomationRun.FAILED, e.message)
        } catch (e: Exception) {
            outcome = Outcome(AutomationRun.FAILED, ChatSessions.MSG_UNEXPECTED)
        } finally {
            pump.close()
            withContext(NonCancellable) {
                val o = outcome ?: Outcome(AutomationRun.STOPPED)
                val out = synchronized(text) { text.toString() }
                val done = finish(run, out.ifEmpty { null }, o.state, o.error, o.detail)
                runCatching { sink?.state(done) }
            }
        }
    }

    companion object {
        const val MAX_AUTOMATIONS = 20
        const val MAX_RUNS = 50
        const val MIN_INTERVAL = 15
        const val MAX_NAME = 80
        const val COPY_SUFFIX = " (copie)"

        const val MSG_GONE = "Cette automatisation n'existe plus"
        const val MSG_RUN_GONE = "Cette exécution n'existe plus"
        const val MSG_NAME = "Donnez un nom à l'automatisation"
        const val MSG_NAME_LONG = "Nom trop long (80 caractères au plus)"
        const val MSG_TRIGGER = "Déclencheur inconnu"
        const val MSG_INTERVAL = "Une automatisation planifiée s'exécute toutes les 15 minutes au plus souvent"
        const val MSG_TOO_MANY = "20 automatisations au plus : supprimez-en une d'abord"
        const val MSG_NO_SERVER = "Aucun serveur IA : ajoutez-en un dans Serveurs IA"
        const val MSG_NO_MODEL = "Aucun modèle choisi : choisissez un modèle pour cette automatisation"
        const val MSG_BUSY = "Cette automatisation est déjà en cours"
        const val MSG_INTERRUPTED = "Exécution interrompue : Portail a été fermé pendant l'exécution"

        fun encodeVars(vars: List<AutomationVar>): String = JSONArray().also { a ->
            for (v in vars) a.put(JSONObject().put("name", v.name).put("default", v.default ?: JSONObject.NULL))
        }.toString()

        fun decodeVars(json: String): List<AutomationVar> {
            if (json.isBlank()) return emptyList()
            val a = JSONArray(json)
            return (0 until a.length()).map { i ->
                val o = a.getJSONObject(i)
                AutomationVar(o.getString("name"), if (o.isNull("default")) null else o.getString("default"))
            }
        }
    }
}
