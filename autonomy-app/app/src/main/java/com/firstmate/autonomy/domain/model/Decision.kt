package com.firstmate.autonomy.domain.model

import java.time.Instant
import java.time.LocalDate

/**
 * One logged choice. The point of the record is the gap between
 * [myPreference] and [finalChoice], and what [reflection] says about it later.
 */
data class Decision(
    val id: Long = 0L,
    val title: String,
    val date: LocalDate,
    val category: DecisionCategory = DecisionCategory.PERSONAL,
    /** What the user actually wanted, ideally written before any negotiation. */
    val myPreference: String = "",
    /** What was ultimately done. */
    val finalChoice: String = "",
    /** "Outcome & How It Felt" - filled in later, so it is optional at entry time. */
    val reflection: String = "",
    val createdAt: Instant = Instant.EPOCH,
    /**
     * The goal this decision was about, if you linked one. Optional because
     * plenty of decisions are not about a goal at all, and forcing a link
     * would turn the log into a filing exercise.
     */
    val goalId: Long? = null,
) {
    /** True when the user's own preference is what happened. */
    val followedOwnPreference: Boolean
        get() = myPreference.isNotBlank() &&
            finalChoice.isNotBlank() &&
            myPreference.trim().equals(finalChoice.trim(), ignoreCase = true)

    val hasReflection: Boolean get() = reflection.isNotBlank()
}

enum class DecisionCategory(val label: String) {
    HOME("Home"),
    PERSONAL("Personal"),
    FAMILY_DYNAMICS("Family Dynamics"),
    WORK("Work"),
    ;

    companion object {
        fun fromStorage(raw: String): DecisionCategory =
            entries.firstOrNull { it.name == raw } ?: PERSONAL
    }
}
