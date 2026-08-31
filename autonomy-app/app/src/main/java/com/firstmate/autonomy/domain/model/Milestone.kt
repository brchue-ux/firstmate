package com.firstmate.autonomy.domain.model

/** A single checkbox-sized step inside a [ProjectDomain]. */
data class Milestone(
    val id: Long = 0L,
    val domainId: Long,
    val title: String,
    val isCompleted: Boolean = false,
    /** Stable ordering independent of insertion id, so items can be reordered later. */
    val position: Int = 0,
)
