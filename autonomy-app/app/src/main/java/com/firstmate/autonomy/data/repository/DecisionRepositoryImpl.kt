package com.firstmate.autonomy.data.repository

import com.firstmate.autonomy.data.local.dao.DecisionDao
import com.firstmate.autonomy.data.local.entity.DecisionEntity
import com.firstmate.autonomy.data.mapper.toDomainModel
import com.firstmate.autonomy.data.mapper.toEntity
import com.firstmate.autonomy.di.IoDispatcher
import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.domain.model.DecisionCategory
import com.firstmate.autonomy.domain.repository.DecisionRepository
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class DecisionRepositoryImpl @Inject constructor(
    private val dao: DecisionDao,
    private val clock: Clock,
    @IoDispatcher private val ioDispatcher: CoroutineDispatcher,
) : DecisionRepository {

    override fun observeDecisions(): Flow<List<Decision>> =
        dao.observeAll()
            .map { rows -> rows.map { it.toDomainModel() } }
            .flowOn(ioDispatcher)

    override fun observeRecentDecisions(limit: Int): Flow<List<Decision>> =
        dao.observeRecent(limit)
            .map { rows -> rows.map { it.toDomainModel() } }
            .flowOn(ioDispatcher)

    override fun observeDecision(id: Long): Flow<Decision?> =
        dao.observeById(id)
            .map { it?.toDomainModel() }
            .flowOn(ioDispatcher)

    override suspend fun createDecision(
        title: String,
        date: LocalDate,
        category: DecisionCategory,
        myPreference: String,
        finalChoice: String,
        reflection: String,
    ): Long = withContext(ioDispatcher) {
        dao.insert(
            DecisionEntity(
                title = title.trim(),
                date = date,
                category = category,
                myPreference = myPreference.trim(),
                finalChoice = finalChoice.trim(),
                reflection = reflection.trim(),
                createdAt = Instant.now(clock),
            ),
        )
    }

    override suspend fun updateDecision(decision: Decision) {
        withContext(ioDispatcher) {
            dao.update(
                decision.copy(
                    title = decision.title.trim(),
                    myPreference = decision.myPreference.trim(),
                    finalChoice = decision.finalChoice.trim(),
                    reflection = decision.reflection.trim(),
                ).toEntity(),
            )
        }
    }

    override suspend fun deleteDecision(id: Long) {
        withContext(ioDispatcher) { dao.deleteById(id) }
    }
}
