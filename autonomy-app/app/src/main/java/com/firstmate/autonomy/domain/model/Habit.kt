package com.firstmate.autonomy.domain.model

import java.time.LocalDate

/**
 * A non-negotiable daily micro-habit: solo time, skill practice,
 * enforcing one boundary.
 */
data class Habit(
    val id: Long = 0L,
    val name: String,
    val description: String = "",
    val isArchived: Boolean = false,
    val position: Int = 0,
)

/** A single day's answer for a single habit. An absent row means "not done". */
data class HabitCheckIn(
    val habitId: Long,
    val date: LocalDate,
    val isCompleted: Boolean,
)

/** A habit paired with today's answer, for the daily check-in list. */
data class HabitWithTodayStatus(
    val habit: Habit,
    val isCompletedToday: Boolean,
)

/**
 * Consistency over a window of days, used by the weekly strip and the
 * monthly summary.
 */
data class HabitConsistency(
    val habit: Habit,
    /** Ordered oldest -> newest, one entry per day in the window. */
    val days: List<DayStatus>,
) {
    val completedCount: Int get() = days.count { it.isCompleted }

    val rate: Float get() = if (days.isEmpty()) 0f else completedCount.toFloat() / days.size

    val ratePercent: Int get() = (rate * 100).toInt()

    /** Consecutive completed days counting back from the most recent day. */
    val currentStreak: Int
        get() = days.asReversed().takeWhile { it.isCompleted }.count()
}

data class DayStatus(
    val date: LocalDate,
    val isCompleted: Boolean,
)
