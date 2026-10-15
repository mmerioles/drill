package io.github.mmerioles.drill.core

// The command palette's matcher and ranking, the same on every platform.

object Fuzzy {
    class Match(val score: Int, val indices: List<Int>)

    /** Greedy left-to-right match of [query] in [text], ignoring case and the
     *  query's spaces; null when some character is missing. */
    fun match(query: String, text: String): Match? {
        val q = query.lowercase().filter { it != ' ' }
        if (q.isEmpty()) return Match(0, emptyList())
        val t = text.lowercase()
        val indices = ArrayList<Int>(q.length)
        var score = 0
        var at = -1
        for (c in q) {
            val i = t.indexOf(c, at + 1)
            if (i < 0) return null
            score += 1
            if (i == 0 || t[i - 1] in " -_/") score += 5
            if (at >= 0 && i == at + 1) score += 3
            indices += i
            at = i
        }
        return Match(score - indices[0], indices)
    }

    fun score(query: String, text: String): Int? = match(query, text)?.score
}

class Command(
    val id: String,
    val title: String,
    val hint: String? = null,
    val keywords: List<String> = emptyList(),
    val run: () -> Unit,
)

/** A command to show, with the title characters to draw in full ink. */
class Hit(val command: Command, val indices: List<Int> = emptyList())

object Commands {
    const val RECENT = 5

    /** Empty query: the [recent] ids first (most recent first), then the rest
     *  in order. Otherwise matches by score, ties in list order, then
     *  [fallback] last when there is one. */
    fun rank(query: String, commands: List<Command>, recent: List<String> = emptyList(), fallback: Command? = null): List<Hit> {
        if (query.isBlank()) {
            val first = recent.take(RECENT).mapNotNull { id -> commands.firstOrNull { it.id == id } }
            return (first + (commands - first.toSet())).map { Hit(it) }
        }
        val scored = commands.mapNotNull { c ->
            val title = Fuzzy.match(query, c.title)
            val keyword = c.keywords.mapNotNull { Fuzzy.score(query, it) }.maxOrNull()?.minus(2)
            val best = listOfNotNull(title?.score, keyword).maxOrNull() ?: return@mapNotNull null
            best to Hit(c, title?.indices.orEmpty())
        }
        return scored.sortedByDescending { it.first }.map { it.second } + listOfNotNull(fallback?.let { Hit(it) })
    }
}
