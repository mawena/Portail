package com.mawena.fluluks.ai

import kotlinx.coroutines.flow.Flow

/**
 * Serveur IA (phase 15, spec § 23) vu par Portail : santé, modèles, chat en flux ou d'un bloc, embeddings. Une seule
 * implémentation pour l'instant ([OpenAiCompatibleProvider], contrat de `docs/ia/contrat-api.md`), d'autres types de
 * serveurs pourront s'ajouter. Les erreurs sont des [AiException] au message français.
 */
interface AiProvider {
    /** État du serveur ; ne lève jamais (un échec donne [AiHealth.State.OFFLINE] avec la raison). */
    suspend fun health(): AiHealth

    suspend fun models(): List<AiModel>

    /**
     * Réponse en flux : des [ChatEvent.Delta], puis exactement un [ChatEvent.Done] ou un [ChatEvent.Failed] ; ne lève
     * jamais. Annuler la collecte annule l'appel HTTP (la connexion est fermée) : plus aucun événement n'arrive.
     */
    fun chat(req: ChatRequest): Flow<ChatEvent>

    /** Réponse entière, sans flux (automatisations). */
    suspend fun complete(req: ChatRequest): String

    /** Facultatif côté serveur (404 : [AiException.Kind.NOT_FOUND]) ; prévu pour une recherche sémantique. */
    suspend fun embeddings(model: String, input: List<String>): List<FloatArray>
}

/**
 * État d'un serveur : [version] lue sur `/health` (null si absente) ; [error] : pourquoi il est hors ligne ou pourquoi
 * la clé est refusée ; [modelCount] : nombre de modèles quand `/v1/models` a répondu.
 */
data class AiHealth(val state: State, val version: String?, val error: AiException?, val modelCount: Int? = null) {
    enum class State { ONLINE, OFFLINE, KEY_REFUSED }
}

data class AiModel(val id: String, val ownedBy: String?)

/** Message d'une conversation : [role] `system`, `user` ou `assistant`. */
data class ChatMessage(val role: String, val content: String)

/** [temperature] et [maxTokens] envoyés seulement s'ils sont choisis (sinon, valeurs du serveur). */
data class ChatRequest(
    val model: String,
    val messages: List<ChatMessage>,
    val temperature: Double? = null,
    val maxTokens: Int? = null,
)

data class Usage(val promptTokens: Int?, val completionTokens: Int?)

sealed class ChatEvent {
    data class Delta(val text: String) : ChatEvent()

    data class Done(val finishReason: String?, val usage: Usage?) : ChatEvent()

    data class Failed(val error: AiException) : ChatEvent()
}

/** Délais (spec, valeurs fixées) ; modifiables pour les tests. */
data class AiTimeouts(
    val connectMs: Long = 10_000,
    val readMs: Long = 120_000,
    /** En flux : temps au plus sans aucun octet reçu. */
    val streamIdleMs: Long = 60_000,
    val healthMs: Long = 5_000,
)
