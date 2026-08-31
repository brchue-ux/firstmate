package com.firstmate.autonomy.domain.repository

import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.Milestone
import com.firstmate.autonomy.domain.model.ProjectDomain
import kotlinx.coroutines.flow.Flow

/**
 * Contract for personal-project storage. The UI layer depends on this, never on Room.
 */
interface DomainRepository {

    /** Every domain with its milestones attached, newest activity first. */
    fun observeDomains(): Flow<List<ProjectDomain>>

    /** Emits null if the domain is deleted while the detail screen is open. */
    fun observeDomain(id: Long): Flow<ProjectDomain?>

    /** Returns the id of the created row. */
    suspend fun createDomain(
        title: String,
        category: String,
        status: DomainStatus,
        notes: String,
    ): Long

    suspend fun updateDomain(
        id: Long,
        title: String,
        category: String,
        status: DomainStatus,
        notes: String,
    )

    suspend fun deleteDomain(id: Long)

    suspend fun addMilestone(domainId: Long, title: String)

    suspend fun setMilestoneCompleted(milestoneId: Long, isCompleted: Boolean)

    suspend fun renameMilestone(milestoneId: Long, title: String)

    suspend fun deleteMilestone(milestone: Milestone)
}
