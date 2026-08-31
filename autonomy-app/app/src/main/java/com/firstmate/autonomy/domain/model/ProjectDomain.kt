package com.firstmate.autonomy.domain.model

import java.time.Instant

/**
 * A solo project or personal space the user owns end to end - a home workshop,
 * a technical setup, a skill they are practising.
 *
 * Named [ProjectDomain] rather than `Domain` so the word does not collide with the
 * architectural layer of the same name.
 */
data class ProjectDomain(
    val id: Long = 0L,
    val title: String,
    val category: String,
    val status: DomainStatus = DomainStatus.PLANNING,
    /** Free-form "Notes & Specifications" - parts lists, settings, measurements. */
    val notes: String = "",
    val milestones: List<Milestone> = emptyList(),
    val createdAt: Instant = Instant.EPOCH,
    val updatedAt: Instant = Instant.EPOCH,
) {
    val completedMilestoneCount: Int get() = milestones.count { it.isCompleted }

    val milestoneCount: Int get() = milestones.size

    /**
     * Completion in the range 0f..1f, derived purely from milestones.
     * A domain with no milestones yet reads as 0% unless it has been explicitly
     * marked [DomainStatus.COMPLETED].
     */
    val progress: Float
        get() = when {
            milestones.isNotEmpty() -> completedMilestoneCount.toFloat() / milestones.size
            status == DomainStatus.COMPLETED -> 1f
            else -> 0f
        }

    val progressPercent: Int get() = (progress * 100).toInt()
}

/** Lifecycle of a personal project. */
enum class DomainStatus(val label: String) {
    PLANNING("Planning"),
    IN_PROGRESS("In Progress"),
    COMPLETED("Completed"),
    ;

    val isActive: Boolean get() = this != COMPLETED

    companion object {
        /** Tolerant lookup so an unknown stored value never crashes a read. */
        fun fromStorage(raw: String): DomainStatus =
            entries.firstOrNull { it.name == raw } ?: PLANNING
    }
}

/** Suggested categories; the field itself accepts any free text. */
object DomainCategories {
    val suggestions = listOf(
        "Workshop",
        "Technical Setup",
        "Skill Practice",
        "Home",
        "Creative",
        "Admin",
    )
}
