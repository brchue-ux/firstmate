package com.firstmate.autonomy.domain.model

import java.time.LocalDate
import java.time.temporal.ChronoUnit

/**
 * What a particular's surface is made of. Purely how it draws - it carries no
 * behaviour - but it is stored rather than derived so a planet you recognise
 * keeps looking the same when you rename it.
 */
enum class SurfaceKind { ROCK, DESERT, BASALT, ICE, GAS, CLOUD, OCEAN, EMBER }

/**
 * Two rates, deliberately on different clocks.
 *
 * [recent] moves fast and sets how warm a planet's surface is. [longRun] moves
 * slowly and sets how much atmosphere it holds and how far frost has crept in.
 * Splitting them is what stops a fortnight of illness undoing a good quarter:
 * missing days cools a planet within a week but cannot strip what it built.
 */
data class Condition(val recent: Float, val longRun: Float) {
    val label: String
        get() = when {
            recent > 0.5f -> "Warm"
            recent > 0.05f -> "Cooling"
            else -> "Frozen"
        }
}

/**
 * A particular: one facet of a goal, and the thing you actually tick.
 *
 * Check-ins live here rather than on the goal, because "did I practise" is
 * rarely one question - scales, passages and playing under pressure each go
 * their own way, and averaging them at the point of entry loses exactly the
 * information you need to see.
 */
data class Particular(
    val id: Long,
    val goalId: Long,
    val title: String,
    val kind: SurfaceKind,
    val notes: String,
    val position: Int,
    val checkInDays: Set<LocalDate> = emptySet(),
    val moments: List<Moment> = emptyList(),
) {
    fun condition(today: LocalDate): Condition =
        Condition(recent = rateOver(today, RECENT_DAYS), longRun = rateOver(today, LONG_RUN_DAYS))

    fun isCheckedOn(date: LocalDate): Boolean = date in checkInDays

    /** Days ticked in the window ending today, inclusive. */
    fun daysIn(today: LocalDate, window: Int): Int {
        val first = today.minusDays((window - 1).toLong())
        return checkInDays.count { !it.isBefore(first) && !it.isAfter(today) }
    }

    /**
     * Moments newest first. Orbit radius grows with age, so this is also the
     * order they sit outward from the planet - and taking the first twelve
     * keeps the recent ones as individual moons while the rest coalesce.
     */
    val momentsByAge: List<Moment> get() = moments.sortedByDescending { it.date }

    private fun rateOver(today: LocalDate, window: Int): Float =
        (daysIn(today, window).toFloat() / window).coerceIn(0f, 1f)

    companion object {
        const val RECENT_DAYS = 7
        const val LONG_RUN_DAYS = 90
    }
}

/** One day of a particular's history, for the week strip. */
data class DayStatus(val date: LocalDate, val isCompleted: Boolean)

/** The last seven days, oldest first, which is how the strip reads. */
fun Particular.week(today: LocalDate): List<DayStatus> =
    (0 until Particular.RECENT_DAYS).map { offset ->
        val day = today.minusDays((Particular.RECENT_DAYS - 1 - offset).toLong())
        DayStatus(date = day, isCompleted = isCheckedOn(day))
    }

/**
 * A moment you named after the fact: a moon.
 *
 * Moments are only ever added, never expired. That is the whole point - the
 * streak they replaced could be wiped out by one bad day, which made the app
 * punish exactly the weeks you most needed it not to.
 */
data class Moment(
    val id: Long,
    val particularId: Long,
    val label: String,
    val date: LocalDate,
    val note: String,
) {
    fun ageDays(today: LocalDate): Long =
        ChronoUnit.DAYS.between(date, today).coerceAtLeast(0L)
}
