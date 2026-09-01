package com.firstmate.autonomy.data.repository

import com.firstmate.autonomy.data.local.dao.DecisionDao
import com.firstmate.autonomy.data.local.dao.GoalDao
import com.firstmate.autonomy.data.local.entity.CheckInEntity
import com.firstmate.autonomy.data.local.entity.GoalEntity
import com.firstmate.autonomy.data.local.entity.MomentEntity
import com.firstmate.autonomy.data.local.entity.ParticularEntity
import com.firstmate.autonomy.data.mapper.toDomain
import com.firstmate.autonomy.di.IoDispatcher
import com.firstmate.autonomy.domain.model.Goal
import com.firstmate.autonomy.domain.model.GoalStatus
import com.firstmate.autonomy.domain.model.SurfaceKind
import com.firstmate.autonomy.domain.repository.GoalRepository
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class GoalRepositoryImpl @Inject constructor(
    private val goalDao: GoalDao,
    private val decisionDao: DecisionDao,
    private val clock: Clock,
    @IoDispatcher private val ioDispatcher: CoroutineDispatcher,
) : GoalRepository {

    override fun observeGoals(): Flow<List<Goal>> =
        goalDao.observeGoals()
            .map { rows -> rows.map { it.toDomain() } }
            .flowOn(ioDispatcher)

    override fun observeGoal(goalId: Long): Flow<Goal?> =
        goalDao.observeGoal(goalId)
            .map { it?.toDomain() }
            .flowOn(ioDispatcher)

    override suspend fun createGoal(title: String, category: String, notes: String): Long =
        withContext(ioDispatcher) {
            val now = Instant.now(clock)
            goalDao.insertGoal(
                GoalEntity(
                    title = title.trim(),
                    category = category.trim(),
                    status = GoalStatus.ACTIVE,
                    notes = notes.trim(),
                    position = goalDao.nextGoalPosition(),
                    createdAt = now,
                    updatedAt = now,
                ),
            )
        }

    override suspend fun updateGoal(
        goalId: Long,
        title: String,
        category: String,
        notes: String,
        status: GoalStatus,
    ) = withContext(ioDispatcher) {
        val existing = goalDao.observeGoal(goalId).first() ?: return@withContext
        goalDao.updateGoal(
            existing.goal.copy(
                title = title.trim(),
                category = category.trim(),
                notes = notes.trim(),
                status = status,
                updatedAt = Instant.now(clock),
            ),
        )
    }

    override suspend fun deleteGoal(goalId: Long) = withContext(ioDispatcher) {
        // Unlink first: the decisions you made about a goal outlive it.
        decisionDao.clearGoalReferences(goalId)
        goalDao.deleteGoal(goalId)
    }

    override suspend fun addParticular(
        goalId: Long,
        title: String,
        kind: SurfaceKind,
        notes: String,
    ): Long = withContext(ioDispatcher) {
        goalDao.insertParticular(
            ParticularEntity(
                goalId = goalId,
                title = title.trim(),
                kind = kind,
                notes = notes.trim(),
                position = goalDao.nextParticularPosition(goalId),
                createdAt = Instant.now(clock),
            ),
        )
    }

    override suspend fun updateParticular(
        particularId: Long,
        goalId: Long,
        title: String,
        kind: SurfaceKind,
        notes: String,
        position: Int,
    ) = withContext(ioDispatcher) {
        goalDao.updateParticular(
            ParticularEntity(
                id = particularId,
                goalId = goalId,
                title = title.trim(),
                kind = kind,
                notes = notes.trim(),
                position = position,
                createdAt = Instant.now(clock),
            ),
        )
    }

    override suspend fun deleteParticular(particularId: Long) = withContext(ioDispatcher) {
        goalDao.deleteParticular(particularId)
    }

    override suspend fun setCheckIn(particularId: Long, date: LocalDate, done: Boolean) =
        withContext(ioDispatcher) {
            if (done) {
                goalDao.insertCheckIn(CheckInEntity(particularId = particularId, date = date))
            } else {
                goalDao.deleteCheckIn(particularId, date.toEpochDay())
            }
        }

    override suspend fun addMoment(
        particularId: Long,
        label: String,
        date: LocalDate,
        note: String,
    ): Long = withContext(ioDispatcher) {
        goalDao.insertMoment(
            MomentEntity(
                particularId = particularId,
                label = label.trim(),
                date = date,
                note = note.trim(),
                createdAt = Instant.now(clock),
            ),
        )
    }

    override suspend fun deleteMoment(momentId: Long) = withContext(ioDispatcher) {
        goalDao.deleteMomentById(momentId)
    }
}
