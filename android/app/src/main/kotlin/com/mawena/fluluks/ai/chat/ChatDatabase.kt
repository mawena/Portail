package com.mawena.fluluks.ai.chat

import androidx.room.Database
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import androidx.room.RoomDatabase

/**
 * Conversation (phase 15) : [title] vide tant que le premier message ne l'a pas fixé (titre automatique) ;
 * [serverId] peut désigner un serveur supprimé depuis (la conversation reste lisible) ; [model] et [systemPrompt]
 * propres à la conversation. Dates en millisecondes depuis l'époque.
 */
@Entity(tableName = "conversations")
data class Conversation(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val title: String,
    val serverId: String?,
    val model: String?,
    val systemPrompt: String?,
    val createdAt: Long,
    val updatedAt: Long,
)

/**
 * Message d'une conversation : [role] `user` ou `assistant` ; [state] parmi [Message.DONE], [Message.STREAMING],
 * [Message.STOPPED], [Message.FAILED], [Message.INTERRUPTED] ; [error] : message français d'un échec.
 */
@Entity(
    tableName = "messages",
    foreignKeys = [
        ForeignKey(
            entity = Conversation::class,
            parentColumns = ["id"],
            childColumns = ["conversationId"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index("conversationId")],
)
data class Message(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val conversationId: Long,
    val role: String,
    val content: String,
    val state: String,
    val error: String?,
    val createdAt: Long,
) {
    companion object {
        const val DONE = "done"
        const val STREAMING = "streaming"
        const val STOPPED = "stopped"
        const val FAILED = "failed"

        /** Génération coupée par l'arrêt de Portail (retrouvée au démarrage). */
        const val INTERRUPTED = "interrupted"
    }
}

/** Base de l'historique des conversations (`chat.db`, stockage privé de l'application). */
@Database(entities = [Conversation::class, Message::class], version = 1, exportSchema = true)
abstract class ChatDatabase : RoomDatabase() {
    abstract fun chatDao(): ChatDao

    companion object {
        const val NAME = "chat.db"
    }
}
