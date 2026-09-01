package com.firstmate.autonomy.domain

import com.firstmate.autonomy.domain.model.Goal
import com.firstmate.autonomy.domain.model.GoalStatus
import com.firstmate.autonomy.domain.model.SurfaceKind
import com.firstmate.autonomy.domain.repository.GoalRepository
import com.firstmate.autonomy.domain.repository.SettingsRepository
import com.firstmate.autonomy.domain.usecase.SeedStarterGoalsUseCase
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

/**
 * Seeding is the one thing in the app that writes goals nobody asked for, so
 * the two rules that stop it being destructive are worth pinning: it runs at
 * most once, and it never adds a title that is already there.
 */
class SeedStarterGoalsUseCaseTest {

    private class FakeSettings(private var seeded: Boolean = false) : SettingsRepository {
        override val celebrationsEnabled: Flow<Boolean> = MutableStateFlow(true)
        override suspend fun setCelebrationsEnabled(enabled: Boolean) = Unit
        override suspend fun starterGoalsSeeded(): Boolean = seeded
        override suspend fun markStarterGoalsSeeded() { seeded = true }
    }

    private class FakeGoals(initial: List<String> = emptyList()) : GoalRepository {
        val goals = MutableStateFlow(
            initial.mapIndexed { index, title ->
                Goal(
                    id = index + 1L, title = title, category = "", status = GoalStatus.ACTIVE,
                    notes = "", position = index, createdAt = Instant.EPOCH,
                )
            },
        )
        val particularsAdded = mutableListOf<Pair<Long, String>>()
        private var nextId = 100L

        override fun observeGoals(): Flow<List<Goal>> = goals
        override fun observeGoal(goalId: Long): Flow<Goal?> =
            goals.map { list -> list.firstOrNull { it.id == goalId } }

        override suspend fun createGoal(title: String, category: String, notes: String): Long {
            val id = nextId++
            goals.value = goals.value + Goal(
                id = id, title = title, category = category, status = GoalStatus.ACTIVE,
                notes = notes, position = goals.value.size, createdAt = Instant.EPOCH,
            )
            return id
        }

        override suspend fun updateGoal(
            goalId: Long, title: String, category: String, notes: String, status: GoalStatus,
        ) = Unit

        override suspend fun deleteGoal(goalId: Long) = Unit

        override suspend fun addParticular(
            goalId: Long, title: String, kind: SurfaceKind, notes: String,
        ): Long {
            particularsAdded += goalId to title
            return nextId++
        }

        override suspend fun updateParticular(
            particularId: Long, goalId: Long, title: String,
            kind: SurfaceKind, notes: String, position: Int,
        ) = Unit

        override suspend fun deleteParticular(particularId: Long) = Unit
        override suspend fun setCheckIn(particularId: Long, date: LocalDate, done: Boolean) = Unit
        override suspend fun addMoment(
            particularId: Long, label: String, date: LocalDate, note: String,
        ): Long = nextId++
        override suspend fun deleteMoment(momentId: Long) = Unit
    }

    @Test
    fun `an empty sky gets the full starter set, each with particulars`() = runTest {
        val goals = FakeGoals()
        val settings = FakeSettings()
        SeedStarterGoalsUseCase(goals, settings)()

        val titles = goals.goals.value.map { it.title }
        assertTrue("Mental health" in titles)
        assertTrue("Physical health" in titles)
        assertTrue("Piano practice" in titles)
        assertTrue("Basement renovation" in titles)
        assertTrue("and some ordinary ones too", titles.size > 4)
        assertTrue("every starter has something to tick", goals.particularsAdded.isNotEmpty())
        goals.goals.value.forEach { goal ->
            assertTrue(
                "${goal.title} has no particulars",
                goals.particularsAdded.any { it.first == goal.id },
            )
        }
    }

    @Test
    fun `a title already entered by hand is left alone`() = runTest {
        val goals = FakeGoals(listOf("Piano practice", "mental HEALTH"))
        SeedStarterGoalsUseCase(goals, FakeSettings())()

        assertEquals(
            "Piano practice was duplicated",
            1, goals.goals.value.count { it.title.equals("Piano practice", ignoreCase = true) },
        )
        assertEquals(
            "the match is case-insensitive",
            1, goals.goals.value.count { it.title.equals("mental health", ignoreCase = true) },
        )
    }

    @Test
    fun `deleting every starter is respected rather than undone`() = runTest {
        val goals = FakeGoals()
        val settings = FakeSettings()
        SeedStarterGoalsUseCase(goals, settings)()
        val afterFirstRun = goals.goals.value.size

        // The person clears the lot, then reopens the app.
        goals.goals.value = emptyList()
        SeedStarterGoalsUseCase(goals, settings)()

        assertTrue("the starters came back after being deleted", goals.goals.value.isEmpty())
        assertTrue("the first run seeded nothing at all", afterFirstRun > 0)
        assertTrue("the flag was never recorded", settings.starterGoalsSeeded())
    }
}
