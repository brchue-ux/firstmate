package com.firstmate.autonomy.data.mapper

import com.firstmate.autonomy.data.local.entity.DecisionEntity
import com.firstmate.autonomy.data.local.entity.HabitCheckInEntity
import com.firstmate.autonomy.data.local.entity.HabitEntity
import com.firstmate.autonomy.data.local.entity.MilestoneEntity
import com.firstmate.autonomy.data.local.relation.DomainWithMilestones
import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.domain.model.DecisionCategory
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.Habit
import com.firstmate.autonomy.domain.model.HabitCheckIn
import com.firstmate.autonomy.domain.model.Milestone
import com.firstmate.autonomy.domain.model.ProjectDomain
import java.time.Instant
import java.time.LocalDate

/**
 * Translation between storage rows and domain models.
 *
 * Keeping it in one file makes the two shapes easy to diff, and keeps
 * `java.time` out of the entities entirely.
 */

fun DomainWithMilestones.toDomainModel(): ProjectDomain = ProjectDomain(
    id = domain.id,
    title = domain.title,
    category = domain.category,
    status = DomainStatus.fromStorage(domain.status),
    notes = domain.notes,
    milestones = milestones
        .sortedWith(compareBy({ it.position }, { it.id }))
        .map { it.toDomainModel() },
    createdAt = Instant.ofEpochMilli(domain.createdAtEpochMilli),
    updatedAt = Instant.ofEpochMilli(domain.updatedAtEpochMilli),
)

fun MilestoneEntity.toDomainModel(): Milestone = Milestone(
    id = id,
    domainId = domainId,
    title = title,
    isCompleted = isCompleted,
    position = position,
)

fun DecisionEntity.toDomainModel(): Decision = Decision(
    id = id,
    title = title,
    date = LocalDate.ofEpochDay(dateEpochDay),
    category = DecisionCategory.fromStorage(category),
    myPreference = myPreference,
    finalChoice = finalChoice,
    reflection = reflection,
    createdAt = Instant.ofEpochMilli(createdAtEpochMilli),
)

fun Decision.toEntity(): DecisionEntity = DecisionEntity(
    id = id,
    title = title,
    dateEpochDay = date.toEpochDay(),
    category = category.name,
    myPreference = myPreference,
    finalChoice = finalChoice,
    reflection = reflection,
    createdAtEpochMilli = createdAt.toEpochMilli(),
)

fun HabitEntity.toDomainModel(): Habit = Habit(
    id = id,
    name = name,
    description = description,
    isArchived = isArchived,
    position = position,
)

fun Habit.toEntity(): HabitEntity = HabitEntity(
    id = id,
    name = name,
    description = description,
    isArchived = isArchived,
    position = position,
)

/** Stored rows only ever represent completed days. */
fun HabitCheckInEntity.toDomainModel(): HabitCheckIn = HabitCheckIn(
    habitId = habitId,
    date = LocalDate.ofEpochDay(dateEpochDay),
    isCompleted = true,
)
