package com.firstmate.autonomy.domain

import com.firstmate.autonomy.domain.model.Goal
import com.firstmate.autonomy.domain.model.GoalStatus
import com.firstmate.autonomy.domain.model.Moment
import com.firstmate.autonomy.domain.model.Particular
import com.firstmate.autonomy.domain.model.SurfaceKind
import com.firstmate.autonomy.domain.model.week
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

/**
 * The point of the two rates is that they move at different speeds. These
 * tests pin exactly that, because it is the behaviour that replaced streaks:
 * a bad week must cool a particular without erasing what the quarter built.
 */
class ParticularConditionTest {

    private val today = LocalDate.of(2026, 3, 12)

    private fun particular(vararg daysAgo: Int) = Particular(
        id = 1L, goalId = 1L, title = "Scales", kind = SurfaceKind.ROCK,
        notes = "", position = 0,
        checkInDays = daysAgo.mapTo(mutableSetOf()) { today.minusDays(it.toLong()) },
    )

    @Test
    fun `an untouched particular is frozen`() {
        val condition = particular().condition(today)
        assertEquals(0f, condition.recent, 0.0001f)
        assertEquals(0f, condition.longRun, 0.0001f)
        assertEquals("Frozen", condition.label)
    }

    @Test
    fun `every day of the week ticked reads as warm`() {
        val condition = particular(0, 1, 2, 3, 4, 5, 6).condition(today)
        assertEquals(1f, condition.recent, 0.0001f)
        assertEquals("Warm", condition.label)
    }

    @Test
    fun `days outside the window do not count toward recent form`() {
        // Ticked solidly, but all of it eight days ago and older.
        val condition = particular(8, 9, 10, 11, 12).condition(today)
        assertEquals(0f, condition.recent, 0.0001f)
        assertTrue("the long run should still see them", condition.longRun > 0f)
    }

    @Test
    fun `a missed fortnight cools the surface without emptying the long run`() {
        // Ninety days of solid work, then fourteen days off.
        val worked = (14..89).toList().toIntArray()
        val condition = particular(*worked).condition(today)
        assertEquals("nothing in the last seven days", 0f, condition.recent, 0.0001f)
        assertTrue("most of the quarter survives", condition.longRun > 0.8f)
    }

    @Test
    fun `the week strip is seven days ending today, oldest first`() {
        val days = particular(0, 3).week(today)
        assertEquals(7, days.size)
        assertEquals(today.minusDays(6), days.first().date)
        assertEquals(today, days.last().date)
        assertTrue(days.last().isCompleted)
        assertTrue(days[3].isCompleted)
    }

    @Test
    fun `a goal averages its particulars rather than taking the best one`() {
        val goal = Goal(
            id = 1L, title = "Piano practice", category = "Craft",
            status = GoalStatus.ACTIVE, notes = "", position = 0,
            createdAt = Instant.EPOCH,
            particulars = listOf(
                particular(0, 1, 2, 3, 4, 5, 6),
                particular().copy(id = 2L),
            ),
        )
        assertEquals(0.5f, goal.warmth(today), 0.0001f)
    }

    @Test
    fun `moments are never expired by a gap in the days`() {
        val withMoments = particular().copy(
            moments = listOf(
                Moment(1L, 1L, "Hands together", today.minusDays(300), ""),
                Moment(2L, 1L, "80bpm", today.minusDays(22), ""),
            ),
        )
        // Frozen solid, and both moments still there.
        assertEquals("Frozen", withMoments.condition(today).label)
        assertEquals(2, withMoments.moments.size)
        assertEquals(300L, withMoments.momentsByAge.last().ageDays(today))
    }
}
