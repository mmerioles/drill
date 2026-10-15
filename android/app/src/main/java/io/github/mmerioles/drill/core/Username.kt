package io.github.mmerioles.drill.core

/** Accounts are a username and a password. Supabase Auth wants an email, so
 *  the apps derive one on our domain and never show it. */
object Username {
    const val DOMAIN = "users.mmerioles.github.io"
    private val RULE = Regex("^[a-z0-9_]{3,20}$")

    fun valid(name: String) = RULE.matches(name)

    /** What typing does to the field: lowercase, no spaces. */
    fun clean(text: String) = text.lowercase().filterNot { it.isWhitespace() }

    fun email(name: String) = "$name@$DOMAIN"

    /** The username behind an account's email. */
    fun fromEmail(email: String) = email.removeSuffix("@$DOMAIN")
}

/** Supabase's floor is 6 characters; bcrypt reads at most 72 bytes. */
object Password {
    fun valid(password: String) =
        password.codePointCount(0, password.length) >= 6 && password.toByteArray(Charsets.UTF_8).size <= 72

    fun confirmed(password: String, confirm: String) = valid(password) && confirm == password
}
