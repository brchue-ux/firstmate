package com.firstmate.autonomy.data.repository

import com.firstmate.autonomy.data.local.dao.HabitDao
import com.firstmate.autonomy.data.local.entity.HabitCheckInEntity
import com.firstmate.autonomy.data.local.entity.HabitEntity
import com.firstmate.autonomy.data.mapper.toDomainModel
import com.firstmate.autonomy.data.mapper.toEntity
import com.firstmate.autonomy.di.IoDispatcher
import com.firstmate.autonomy.domain.model.Habit
import com.firstmate.autonomy.domain.model.HabitCheckIn
import com.firstmate.autonomy.domain.repository.HabitRepository
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.time.LocalDate
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class HabitRepositoryImpl @Inject constructor(
    private val dao: HabitDao,
    @IoDispatcher private val ioDispatcher: CoroutineDispatcher,
) : HabitRepository {

    override fun observeHabits(): Flow<List<Habit>> =
        dao.observeActive()
            .map { rows -> rows.map { it.toDomainModel() } }
            .flowOn(ioDispatcher)

    override fun observeCheckIns(from: LocalDate, to: LocalDate): Flow<List<HabitCheckIn>> =
        dao.observeCheckInsBetween(from, to)
            .map { rows -> rows.map { it.toDomainModel() } }
            .flowOn(ioDispatcher)

    override suspend fun createHabit(name: String, description: String): Long =
        withContext(ioDispatcher) {
            dao.insert(
                HabitEntity(
                    name = name.trim(),
                    description = description.trim(),
                    isArchived = false,
                    position = dao.nextPosition(),
                ),
            )
        }

    override suspend fun updateHabit(habit: Habit) {
        withContext(ioDispatcher) { dao.update(habit.copy(name = habit.name.trim()).toEntity()) }
    }

    override suspend fun archiveHabit(id: Long) {
        withContext(ioDispatcher) { dao.archive(id) }
    }

    override suspend fun deleteHabit(id: Long) {
        withContext(ioDispatcher) { dao.deleteById(id) }
    }

    override suspend fun setCheckIn(habitId: Long, date: LocalDate, isCompleted: Boolean) {
        withContext(ioDispatcher) {
            if (isCompleted) {
                dao.insertCheckIn(HabitCheckInEntity(habitId = habitId, date = date))
            } else {
                dao.deleteCheckIn(habitId, date)
            }
        }
    }
}
