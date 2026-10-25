package com.mawena.fluluks.ai.chat

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Update

/** Accès à l'historique ; appelé hors du fil principal. Les transactions sont tenues par [ChatStore]. */
@Dao
interface ChatDao {
    /** Plus récente d'abord (dernière activité). */
    @Query("SELECT * FROM conversations ORDER BY updatedAt DESC, id DESC")
    fun conversations(): List<Conversation>

    @Query("SELECT * FROM conversations WHERE id = :id")
    fun conversation(id: Long): Conversation?

    @Insert
    fun insertConversation(c: Conversation): Long

    @Update
    fun updateConversation(c: Conversation)

    @Query("DELETE FROM conversations WHERE id = :id")
    fun deleteConversation(id: Long): Int

    /** Dans l'ordre d'écriture. */
    @Query("SELECT * FROM messages WHERE conversationId = :conversationId ORDER BY id")
    fun messages(conversationId: Long): List<Message>

    @Query("SELECT * FROM messages WHERE id = :id")
    fun message(id: Long): Message?

    @Insert
    fun insertMessage(m: Message): Long

    @Update
    fun updateMessage(m: Message)

    @Query("DELETE FROM messages WHERE id = :id")
    fun deleteMessage(id: Long)

    @Query("DELETE FROM messages WHERE conversationId = :conversationId")
    fun deleteMessages(conversationId: Long)

    /** Générations laissées « en cours » par un arrêt de Portail : marquées interrompues. */
    @Query("UPDATE messages SET state = 'interrupted', error = :error, errorDetail = NULL WHERE state = 'streaming'")
    fun markInterrupted(error: String): Int
}
