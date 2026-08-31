package com.firstmate.autonomy.ui.preview

import com.firstmate.autonomy.domain.model.DashboardOverview
import com.firstmate.autonomy.domain.model.DayStatus
import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.domain.model.DecisionCategory
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.Habit
import com.firstmate.autonomy.domain.model.HabitConsistency
import com.firstmate.autonomy.domain.model.HabitWithTodayStatus
import com.firstmate.autonomy.domain.model.Milestone
import com.firstmate.autonomy.domain.model.ProjectDomain
import java.time.Instant
import java.time.LocalDate

/**
 * Fixed sample data for Compose previews and manual UI checks.
 *
 * Deliberately hand-written rather than random: previews should be identical on
 * every render so a visual diff means a real change. Nothing here is ever
 * inserted into the database - the app ships with an empty store.
 */
object PreviewData {

    /** A stable "today" so date-relative previews never drift. */
    val today: LocalDate = LocalDate.of(2026, 3, 12)

    private val createdAt: Instant = Instant.ofEpochMilli(1_772_000_000_000L)

    val workshopDomain = ProjectDomain(
        id = 1L,
        title = "Bench power supply rebuild",
        category = "Workshop",
        status = DomainStatus.IN_PROGRESS,
        notes = "Linear supply, 0-30V / 0-5A.\n" +
            "Toroidal transformer salvaged from the old amp.\n" +
            "Needs a new fan shroud printed before the lid goes back on.",
        milestones = listOf(
            Milestone(1L, 1L, "Strip and catalogue existing parts", isCompleted = true, position = 0),
            Milestone(2L, 1L, "Order replacement filter caps", isCompleted = true, position = 1),
            Milestone(3L, 1L, "Print the fan shroud", isCompleted = true, position = 2),
            Milestone(4L, 1L, "Rewire the front panel", isCompleted = false, position = 3),
            Milestone(5L, 1L, "Load-test at 3A for an hour", isCompleted = false, position = 4),
        ),
        createdAt = createdAt,
        updatedAt = createdAt,
    )

    val homelabDomain = ProjectDomain(
        id = 2L,
        title = "Home server: off-site backups",
        category = "Technical Setup",
        status = DomainStatus.PLANNING,
        notes = "Decide between a second NAS at my brother's place or object storage.\n" +
            "Encryption happens locally either way.",
        milestones = listOf(
            Milestone(6L, 2L, "Write down the restore test I actually want", isCompleted = true, position = 0),
            Milestone(7L, 2L, "Price both options for three years", isCompleted = false, position = 1),
            Milestone(8L, 2L, "Pick one and stop researching", isCompleted = false, position = 2),
        ),
        createdAt = createdAt,
        updatedAt = createdAt,
    )

    val guitarDomain = ProjectDomain(
        id = 3L,
        title = "Fingerstyle practice - 20 minutes daily",
        category = "Skill Practice",
        status = DomainStatus.COMPLETED,
        notes = "Twelve-week block finished. Travis picking is now automatic.",
        milestones = listOf(
            Milestone(9L, 3L, "Weeks 1-4: thumb independence", isCompleted = true, position = 0),
            Milestone(10L, 3L, "Weeks 5-8: two full arrangements", isCompleted = true, position = 1),
            Milestone(11L, 3L, "Weeks 9-12: play one from memory", isCompleted = true, position = 2),
        ),
        createdAt = createdAt,
        updatedAt = createdAt,
    )

    /** A project with no milestones yet, for the 0% / empty-milestones state. */
    val emptyDomain = ProjectDomain(
        id = 4L,
        title = "Reorganise the garage shelving",
        category = "Home",
        status = DomainStatus.PLANNING,
        notes = "",
        milestones = emptyList(),
        createdAt = createdAt,
        updatedAt = createdAt,
    )

    val domains = listOf(workshopDomain, homelabDomain, emptyDomain, guitarDomain)

    val decisions = listOf(
        Decision(
            id = 1L,
            title = "Kept Sunday morning for the workshop",
            date = today,
            category = DecisionCategory.FAMILY_DYNAMICS,
            myPreference = "Three uninterrupted hours in the workshop, phone in the kitchen.",
            finalChoice = "Three uninterrupted hours in the workshop, phone in the kitchen.",
            reflection = "Said it once, plainly, and did not re-explain it. " +
                "Nobody was upset. I noticed I expected an argument that never came.",
            createdAt = createdAt,
        ),
        Decision(
            id = 2L,
            title = "Chose the cheaper oscilloscope",
            date = today.minusDays(3),
            category = DecisionCategory.PERSONAL,
            myPreference = "The 4-channel unit, because I will grow into it.",
            finalChoice = "The 2-channel unit.",
            reflection = "Talked myself down from the one I wanted. It is fine for now, " +
                "but I want to notice next time whether that was thrift or flinching.",
            createdAt = createdAt,
        ),
        Decision(
            id = 3L,
            title = "Declined the weekend on-call swap",
            date = today.minusDays(9),
            category = DecisionCategory.WORK,
            myPreference = "No - I already covered two swaps this month.",
            finalChoice = "No.",
            reflection = "",
            createdAt = createdAt,
        ),
        Decision(
            id = 4L,
            title = "Bought the kitchen table I liked",
            date = today.minusDays(21),
            category = DecisionCategory.HOME,
            myPreference = "The plain oak one.",
            finalChoice = "The plain oak one.",
            reflection = "Still glad about it a month later.",
            createdAt = createdAt,
        ),
    )

    val habits = listOf(
        Habit(id = 1L, name = "Two hours of solo time", description = "No screens, no company", position = 0),
        Habit(id = 2L, name = "Skill practice", description = "20 minutes, anything hands-on", position = 1),
        Habit(id = 3L, name = "Held one boundary", description = "Said the thing I meant to say", position = 2),
    )

    /** Seven-day windows with deliberately different shapes: strong, patchy, new. */
    val habitConsistency: List<HabitConsistency> = listOf(
        habits[0].consistency(listOf(true, true, true, false, true, true, true)),
        habits[1].consistency(listOf(true, false, false, true, true, false, true)),
        habits[2].consistency(listOf(false, false, false, false, false, false, false)),
    )

    val habitsToday = habitConsistency.map {
        HabitWithTodayStatus(habit = it.habit, isCompletedToday = it.days.last().isCompleted)
    }

    val dashboard = DashboardOverview(
        activeDomains = listOf(workshopDomain, homelabDomain, emptyDomain),
        completedDomainCount = 1,
        recentDecisions = decisions.take(3),
        todayHabits = habitsToday,
        weeklyHabitRate = habitConsistency.sumOf { it.completedCount }.toFloat() /
            habitConsistency.sumOf { it.days.size },
    )

    /** Everything empty - the first-run state every screen must handle. */
    val emptyDashboard = DashboardOverview()

    private fun Habit.consistency(pattern: List<Boolean>) = HabitConsistency(
        habit = this,
        days = pattern.mapIndexed { index, completed ->
            DayStatus(
                date = today.minusDays((pattern.size - 1 - index).toLong()),
                isCompleted = completed,
            )
        },
    )
}
