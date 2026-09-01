package com.firstmate.autonomy.domain.model

/** One particular surfaced on Today, with whether it has been ticked yet. */
data class TodayItem(
    val goalId: Long,
    val goalTitle: String,
    val particular: Particular,
    val isDoneToday: Boolean,
    val condition: Condition,
)

/**
 * Everything the Today tab shows, assembled in one place.
 *
 * Today lists particulars rather than goals, because a particular is the thing
 * you actually tick. Listing goals would mean one more tap before any day can
 * be logged, on the screen designed to make logging fast.
 */
data class TodayOverview(
    val items: List<TodayItem> = emptyList(),
    val recentDecisions: List<Decision> = emptyList(),
    val goalCount: Int = 0,
    val momentCount: Int = 0,
) {
    val doneToday: Int get() = items.count { it.isDoneToday }

    val hasAnything: Boolean get() = items.isNotEmpty() || recentDecisions.isNotEmpty()

    /** Share of today's particulars already ticked, 0f..1f. */
    val todayRate: Float
        get() = if (items.isEmpty()) 0f else doneToday.toFloat() / items.size

    /** The coldest things first: what has gone quiet is what needs seeing. */
    val needingAttention: List<TodayItem>
        get() = items.filterNot { it.isDoneToday }.sortedBy { it.condition.recent }
}
