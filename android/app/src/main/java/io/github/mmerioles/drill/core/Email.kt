package io.github.mmerioles.drill.core

/** Accounts are an email and a password. */
object Email {
    private val RULE = Regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")

    /** What typing does to the field: lowercase, no spaces. */
    fun clean(text: String) = text.lowercase().filterNot { it.isWhitespace() }

    fun isValid(email: String) = email.length <= 254 && RULE.matches(email)
}

/** Supabase's floor is 6 characters; bcrypt reads at most 72 bytes. */
object Password {
    fun valid(password: String) =
        password.codePointCount(0, password.length) >= 6 && password.toByteArray(Charsets.UTF_8).size <= 72

    fun confirmed(password: String, confirm: String) = valid(password) && confirm == password
}
