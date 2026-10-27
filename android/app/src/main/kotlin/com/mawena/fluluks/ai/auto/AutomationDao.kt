package com.mawena.fluluks.ai.auto

import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RoomDatabase
import androidx.room.Update

/**
 * Automatisation (phase 15, T8) : modèle de prompt [template] et ses [variables] (JSON : `[{name, default}]`), serveur et
 * modèle visés, prompt système facultatif ; [trigger] [MANUAL] ou [PERIODIC] (toutes les [intervalMinutes] minutes,
 * 15 au moins). [serverId] peut désigner un serveur supprimé depuis (l'exécution échoue alors avec la raison). Dates en
 * millisecondes depuis l'époque.
 */
@Entity(tableName = "automations")
data class Automation(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val name: String,
    val template: String,
    val variables: String,
    val serverId: String?,
    val model: String?,
    val systemPrompt: String?,
    val trigger: String,
    val intervalMinutes: Int?,
    val enabled: Boolean,
    val createdAt: Long,
    val updatedAt: Long,
) {
    companion object {
        const val MANUAL = "manual"
        const val PERIODIC = "periodic"
    }
}

/**
 * Exécution d'une automatisation : [input] est le prompt envoyé (variables remplacées) ; [state] parmi [RUNNING],
 * [DONE], [FAILED], [STOPPED], [INTERRUPTED] ; [error] : message français d'un échec, [errorDetail] : message du
 * serveur ; [scheduled] : lancée par la planification (sinon, à la main).
 */
@Entity(
    tableName = "automation_runs",
    foreignKeys = [
        ForeignKey(
            entity = Automation::class,
            parentColumns = ["id"],
            childColumns = ["automationId"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index("automationId")],
)
data class AutomationRun(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val automationId: Long,
    val startedAt: Long,
    val endedAt: Long?,
    val state: String,
    val scheduled: Boolean,
    val input: String,
    val output: String?,
    val error: String?,
    val errorDetail: String?,
) {
    companion object {
        const val RUNNING = "running"
        const val DONE = "done"
        const val FAILED = "failed"
        const val STOPPED = "stopped"

        /** Exécution coupée par l'arrêt de Portail (retrouvée au démarrage). */
        const val INTERRUPTED = "interrupted"
    }
}

/** Accès aux automatisations ; appelé hors du fil principal. Les transactions sont tenues par [Automations]. */
@Dao
interface AutomationDao {
    @Query("SELECT * FROM automations ORDER BY id")
    fun automations(): List<Automation>

    @Query("SELECT * FROM automations WHERE id = :id")
    fun automation(id: Long): Automation?

    @Query("SELECT * FROM automations WHERE serverId = :serverId")
    fun automationsOf(serverId: String): List<Automation>

    @Query("SELECT COUNT(*) FROM automations")
    fun count(): Int

    @Insert
    fun insertAutomation(a: Automation): Long

    @Update
    fun updateAutomation(a: Automation)

    @Query("DELETE FROM automations WHERE id = :id")
    fun deleteAutomation(id: Long): Int

    /** Plus récente d'abord. */
    @Query("SELECT * FROM automation_runs WHERE automationId = :automationId ORDER BY id DESC")
    fun runs(automationId: Long): List<AutomationRun>

    @Query("SELECT * FROM automation_runs WHERE id = :id")
    fun run(id: Long): AutomationRun?

    @Query("SELECT * FROM automation_runs WHERE automationId = :automationId ORDER BY id DESC LIMIT 1")
    fun lastRun(automationId: Long): AutomationRun?

    @Insert
    fun insertRun(r: AutomationRun): Long

    @Update
    fun updateRun(r: AutomationRun)

    @Query("DELETE FROM automation_runs WHERE automationId = :automationId")
    fun deleteRuns(automationId: Long)

    /** Garde les [keep] exécutions les plus récentes de l'automatisation. */
    @Query(
        "DELETE FROM automation_runs WHERE automationId = :automationId AND id NOT IN " +
            "(SELECT id FROM automation_runs WHERE automationId = :automationId ORDER BY id DESC LIMIT :keep)",
    )
    fun pruneRuns(automationId: Long, keep: Int)

    /** Exécutions laissées « en cours » par un arrêt de Portail : marquées interrompues. */
    @Query("UPDATE automation_runs SET state = 'interrupted', error = :error, endedAt = :at WHERE state = 'running'")
    fun markInterrupted(error: String, at: Long): Int
}

/** Base des automatisations (`automations.db`, stockage privé de l'application). */
@Database(entities = [Automation::class, AutomationRun::class], version = 1, exportSchema = true)
abstract class AutomationDatabase : RoomDatabase() {
    abstract fun automationDao(): AutomationDao

    companion object {
        const val NAME = "automations.db"
    }
}
