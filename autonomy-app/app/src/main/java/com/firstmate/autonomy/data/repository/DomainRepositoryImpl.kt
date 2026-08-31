package com.firstmate.autonomy.data.repository

import com.firstmate.autonomy.data.local.dao.DomainDao
import com.firstmate.autonomy.data.local.entity.DomainEntity
import com.firstmate.autonomy.data.local.entity.MilestoneEntity
import com.firstmate.autonomy.data.mapper.toDomainModel
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.Milestone
import com.firstmate.autonomy.domain.model.ProjectDomain
import com.firstmate.autonomy.domain.repository.DomainRepository
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.time.Clock

class DomainRepositoryImpl(
    private val dao: DomainDao,
    private val clock: Clock = Clock.systemDefaultZone(),
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : DomainRepository {

    override fun observeDomains(): Flow<List<ProjectDomain>> =
        dao.observeAll()
            .map { rows -> rows.map { it.toDomainModel() } }
            .flowOn(ioDispatcher)

    override fun observeDomain(id: Long): Flow<ProjectDomain?> =
        dao.observeById(id)
            .map { it?.toDomainModel() }
            .flowOn(ioDispatcher)

    override suspend fun createDomain(
        title: String,
        category: String,
        status: DomainStatus,
        notes: String,
    ): Long = withContext(ioDispatcher) {
        val now = clock.millis()
        dao.insert(
            DomainEntity(
                title = title.trim(),
                category = category.trim(),
                status = status.name,
                notes = notes,
                createdAtEpochMilli = now,
                updatedAtEpochMilli = now,
            ),
        )
    }

    override suspend fun updateDomain(
        id: Long,
        title: String,
        category: String,
        status: DomainStatus,
        notes: String,
    ) = withContext(ioDispatcher) {
        dao.update(
            id = id,
            title = title.trim(),
            category = category.trim(),
            status = status.name,
            notes = notes,
            updatedAtEpochMilli = clock.millis(),
        )
    }

    override suspend fun deleteDomain(id: Long) {
        withContext(ioDispatcher) { dao.deleteById(id) }
    }

    override suspend fun addMilestone(domainId: Long, title: String) {
        withContext(ioDispatcher) {
            dao.insertMilestone(
                MilestoneEntity(
                    domainId = domainId,
                    title = title.trim(),
                    isCompleted = false,
                    position = dao.nextMilestonePosition(domainId),
                ),
            )
            // Milestone activity counts as project activity for list ordering.
            dao.touch(domainId, clock.millis())
        }
    }

    override suspend fun setMilestoneCompleted(milestoneId: Long, isCompleted: Boolean) {
        withContext(ioDispatcher) {
            dao.setMilestoneCompleted(milestoneId, isCompleted)
            dao.domainIdForMilestone(milestoneId)?.let { dao.touch(it, clock.millis()) }
        }
    }

    override suspend fun renameMilestone(milestoneId: Long, title: String) {
        withContext(ioDispatcher) {
            dao.renameMilestone(milestoneId, title.trim())
            dao.domainIdForMilestone(milestoneId)?.let { dao.touch(it, clock.millis()) }
        }
    }

    override suspend fun deleteMilestone(milestone: Milestone) {
        withContext(ioDispatcher) {
            dao.deleteMilestone(milestone.id)
            dao.touch(milestone.domainId, clock.millis())
        }
    }
}
