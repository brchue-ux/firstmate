package com.firstmate.autonomy.ui.preview

import com.firstmate.autonomy.domain.model.Condition
import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.domain.model.DecisionCategory
import com.firstmate.autonomy.domain.model.Goal
import com.firstmate.autonomy.domain.model.GoalStatus
import com.firstmate.autonomy.domain.model.Moment
import com.firstmate.autonomy.domain.model.Particular
import com.firstmate.autonomy.domain.model.SurfaceKind
import com.firstmate.autonomy.domain.model.TodayItem
import com.firstmate.autonomy.domain.model.TodayOverview
import java.time.Instant
import java.time.LocalDate

/**
 * Sample content for previews and for the space view's first run.
 *
 * Every preview in the app draws from here so no screen invents its own
 * placeholder text, and so a change to the shape of a model breaks in one file
 * rather than twenty.
 */
object PreviewData {

    /** Pinned, so previews and dated assertions never drift with the wall clock. */
    val today: LocalDate = LocalDate.of(2026, 3, 12)

    private val created: Instant = Instant.parse("2025-06-01T09:00:00Z")

    /** Ticks the given day offsets back from [today]. */
    private fun days(vararg offsets: Int): Set<LocalDate> =
        offsets.mapTo(mutableSetOf()) { today.minusDays(it.toLong()) }

    private fun moment(id: Long, particularId: Long, label: String, ageDays: Long) =
        Moment(id, particularId, label, today.minusDays(ageDays), "")

    val scales = Particular(
        id = 1L, goalId = 1L, title = "Scales", kind = SurfaceKind.DESERT,
        notes = "Two octaves, hands together, 60bpm.", position = 0,
        checkInDays = days(0, 1, 2, 3, 5, 6, 8, 9, 11, 13, 15, 18, 21, 25),
        moments = listOf(
            moment(1L, 1L, "Hands together", 300),
            moment(2L, 1L, "60bpm steady", 120),
            moment(3L, 1L, "80bpm both hands", 22),
        ),
    )

    val passages = Particular(
        id = 2L, goalId = 1L, title = "Passages", kind = SurfaceKind.ROCK,
        notes = "Bars 41-58 of the Chopin.", position = 1,
        checkInDays = days(1, 4, 9, 12, 17, 23, 28),
        moments = listOf(moment(4L, 2L, "Whole page, no stops", 9)),
    )

    val pressure = Particular(
        id = 3L, goalId = 1L, title = "Pressure", kind = SurfaceKind.BASALT,
        notes = "Playing through nerves. Record it.", position = 2,
        checkInDays = days(14, 29, 41),
        moments = listOf(moment(5L, 3L, "Played it for Sam", 64)),
    )

    val chords = Particular(
        id = 4L, goalId = 1L, title = "Chords", kind = SurfaceKind.ICE,
        notes = "Rootless voicings, ii-V-I.", position = 3,
    )

    val piano = Goal(
        id = 1L,
        title = "Piano practice",
        category = "Craft",
        status = GoalStatus.ACTIVE,
        notes = "Put the grade exams down and just play.",
        position = 0,
        createdAt = created,
        particulars = listOf(scales, passages, pressure, chords),
    )

    val gym = Goal(
        id = 2L,
        title = "Getting strong",
        category = "Body",
        status = GoalStatus.ACTIVE,
        notes = "Three sessions. Recovery is the limit, not effort.",
        position = 1,
        createdAt = created,
        particulars = listOf(
            Particular(
                id = 5L, goalId = 2L, title = "Squat", kind = SurfaceKind.EMBER,
                notes = "5x5. 92kg working set.", position = 0,
                checkInDays = days(0, 2, 4, 7, 9, 11, 14),
                moments = listOf(moment(6L, 5L, "92kg for reps", 26)),
            ),
            Particular(
                id = 6L, goalId = 2L, title = "Deadlift", kind = SurfaceKind.ROCK,
                notes = "Once a week is enough.", position = 1,
                checkInDays = days(3, 10, 17, 24),
                moments = listOf(moment(7L, 6L, "140kg", 180)),
            ),
        ),
    )

    val basement = Goal(
        id = 3L,
        title = "Basement renovation",
        category = "Home",
        status = GoalStatus.ACTIVE,
        notes = "Doing the wiring myself rather than hiring out.",
        position = 2,
        createdAt = created,
        particulars = listOf(
            Particular(
                id = 7L, goalId = 3L, title = "Wiring", kind = SurfaceKind.EMBER,
                notes = "Two circuits left to pull.", position = 0,
                checkInDays = days(1, 6, 13),
                moments = listOf(moment(8L, 7L, "First circuit live", 22)),
            ),
            Particular(
                id = 8L, goalId = 3L, title = "Insulation", kind = SurfaceKind.BASALT,
                notes = "Not started.", position = 1,
            ),
        ),
    )

    /** A goal that has gone cold, so empty and frozen states have something to draw. */
    val spanish = Goal(
        id = 4L,
        title = "Spanish",
        category = "Craft",
        status = GoalStatus.PAUSED,
        notes = "Untouched since April.",
        position = 3,
        createdAt = created,
        particulars = listOf(
            Particular(
                id = 9L, goalId = 4L, title = "Vocab", kind = SurfaceKind.BASALT,
                notes = "Anki deck untouched.", position = 0,
                moments = listOf(moment(9L, 9L, "500 words held", 300)),
            ),
        ),
    )

    val emptyGoal = Goal(
        id = 5L,
        title = "Photography",
        category = "Craft",
        status = GoalStatus.ACTIVE,
        notes = "",
        position = 4,
        createdAt = created,
    )

    val goals = listOf(piano, gym, basement, spanish, emptyGoal)

    val decisions = listOf(
        Decision(
            id = 1L,
            title = "Put the grade exams down",
            date = today.minusDays(42),
            category = DecisionCategory.PERSONAL,
            myPreference = "Stop working to a syllabus and just play",
            finalChoice = "Stop working to a syllabus and just play",
            reflection = "Practice stopped feeling like homework within a fortnight.",
            createdAt = created,
            goalId = 1L,
        ),
        Decision(
            id = 2L,
            title = "Drop the fourth gym session",
            date = today.minusDays(21),
            category = DecisionCategory.PERSONAL,
            myPreference = "Three sessions, properly recovered",
            finalChoice = "Three sessions, properly recovered",
            reflection = "",
            createdAt = created,
            goalId = 2L,
        ),
        Decision(
            id = 3L,
            title = "Do the basement wiring myself",
            date = today.minusDays(30),
            category = DecisionCategory.HOME,
            myPreference = "Hire an electrician for the whole run",
            finalChoice = "Pull the circuits myself, pay for the inspection",
            reflection = "Slower than hiring out, and I now know where every cable is.",
            createdAt = created,
            goalId = 3L,
        ),
    )

    val todayItems: List<TodayItem> = goals
        .filter { it.status == GoalStatus.ACTIVE }
        .flatMap { goal ->
            goal.particulars.map { particular ->
                TodayItem(
                    goalId = goal.id,
                    goalTitle = goal.title,
                    particular = particular,
                    isDoneToday = particular.isCheckedOn(today),
                    condition = particular.condition(today),
                )
            }
        }

    val todayOverview = TodayOverview(
        items = todayItems,
        recentDecisions = decisions,
        goalCount = goals.size,
        momentCount = goals.sumOf { it.momentCount },
    )

    val emptyOverview = TodayOverview()

    val warmCondition: Condition = scales.condition(today)
    val frozenCondition: Condition = chords.condition(today)
}
