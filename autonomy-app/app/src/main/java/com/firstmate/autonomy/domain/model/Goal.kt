package com.firstmate.autonomy.domain.model

import java.time.Instant
import java.time.LocalDate

/** Where a goal stands. A paused goal still renders; it just stops asking for days. */
enum class GoalStatus(val label: String) {
    ACTIVE("Active"),
    PAUSED("Paused"),
    DONE("Done"),
    ;

    /** True while this goal still expects days from you. */
    val isLive: Boolean get() = this == ACTIVE
}

/**
 * One goal: a galaxy in the space view.
 *
 * This type replaces the old separate Domain and Habit. They were always the
 * same thing wearing two labels - something you are trying to keep doing - and
 * splitting them forced the same work to be entered twice. What used to be a
 * habit is now a goal whose particulars you tick; what used to be a project is
 * now a goal whose particulars you tick less often.
 *
 * The condition figures below are averages over the goal's particulars, so a
 * goal cannot look warm while everything under it has gone cold.
 */
data class Goal(
    val id: Long,
    val title: String,
    val category: String,
    val status: GoalStatus,
    val notes: String,
    val position: Int,
    val createdAt: Instant,
    val particulars: List<Particular> = emptyList(),
) {
    /** Recent activity, 0..1. Drives how warm this goal's galaxy burns. */
    fun warmth(today: LocalDate): Float = average { it.condition(today).recent }

    /** Long-run activity, 0..1. Drives how much structure the galaxy holds. */
    fun depth(today: LocalDate): Float = average { it.condition(today).longRun }

    /** Every moment named against every particular of this goal. */
    val momentCount: Int get() = particulars.sumOf { it.moments.size }

    /**
     * How brightly this galaxy renders, 0..1. Weighted toward the long run so a
     * quiet week dims a goal without making it look abandoned.
     */
    fun liveliness(today: LocalDate): Float =
        (warmth(today) * 0.35f + depth(today) * 0.65f).coerceIn(0f, 1f)

    private inline fun average(select: (Particular) -> Float): Float =
        if (particulars.isEmpty()) 0f
        else particulars.map(select).average().toFloat().coerceIn(0f, 1f)
}
