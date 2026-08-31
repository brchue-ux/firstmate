package com.firstmate.autonomy.domain.model

/** Everything the home screen shows, assembled in one place. */
data class DashboardOverview(
    val activeDomains: List<ProjectDomain> = emptyList(),
    val completedDomainCount: Int = 0,
    val recentDecisions: List<Decision> = emptyList(),
    val todayHabits: List<HabitWithTodayStatus> = emptyList(),
    /** Completion rate across all tracked habits for the last seven days. */
    val weeklyHabitRate: Float = 0f,
) {
    val hasAnything: Boolean
        get() = activeDomains.isNotEmpty() ||
            completedDomainCount > 0 ||
            recentDecisions.isNotEmpty() ||
            todayHabits.isNotEmpty()

    val todayCompletedCount: Int get() = todayHabits.count { it.isCompletedToday }

    /** Average completion across active domains, 0f..1f. */
    val averageDomainProgress: Float
        get() = if (activeDomains.isEmpty()) 0f else activeDomains.map { it.progress }.average().toFloat()
}
