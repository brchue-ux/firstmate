package com.firstmate.autonomy.data.mapper

import com.firstmate.autonomy.data.local.entity.DecisionEntity
import com.firstmate.autonomy.data.local.entity.HabitCheckInEntity
import com.firstmate.autonomy.data.local.entity.HabitEntity
import com.firstmate.autonomy.data.local.entity.MilestoneEntity
import com.firstmate.autonomy.data.local.relation.DomainWithMilestones
import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.domain.model.Habit
import com.firstmate.autonomy.domain.model.HabitCheckIn
import com.firstmate.autonomy.domain.model.Milestone
import com.firstmate.autonomy.domain.model.ProjectDomain

/**
 * Storage rows to domain models.
 *
 * These stayed after TypeConverters took over the primitive marshalling,
 * because the boundary they defend is architectural rather than mechanical:
 * domain models carry no Room annotations, so nothing above `data/` can end up
 * depending on the persistence framework.
 */

fun DomainWithMilestones.toDomainModel(): ProjectDomain = ProjectDomain(
    id = domain.id,
    title = domain.title,
    category = domain.category,
    status = domain.status,
    notes = domain.notes,
    milestones = milestones
        .sortedWith(compareBy({ it.position }, { it.id }))
        .map { it.toDomainModel() },
    createdAt = domain.createdAt,
    updatedAt = domain.updatedAt,
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
    date = date,
    category = category,
    myPreference = myPreference,
    finalChoice = finalChoice,
    reflection = reflection,
    createdAt = createdAt,
)

fun Decision.toEntity(): DecisionEntity = DecisionEntity(
    id = id,
    title = title,
    date = date,
    category = category,
    myPreference = myPreference,
    finalChoice = finalChoice,
    reflection = reflection,
    createdAt = createdAt,
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
    date = date,
    isCompleted = true,
)
