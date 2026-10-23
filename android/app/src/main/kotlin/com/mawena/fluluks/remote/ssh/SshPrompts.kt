package com.mawena.fluluks.remote.ssh

/**
 * Invites keyboard-interactive posées à l'utilisateur (code de vérification, mot de passe demandé autrement que par
 * « Password: ») : [name] et [instruction] du serveur, une réponse par invite de [prompts] ([echo] : la saisie peut
 * s'afficher). null : l'utilisateur a refusé ou n'a pas répondu à temps. Les réponses sont remises à zéro par
 * l'appelant après usage.
 */
fun interface SshPrompts {
    fun ask(name: String, instruction: String, prompts: List<String>, echo: List<Boolean>): List<ByteArray>?
}
