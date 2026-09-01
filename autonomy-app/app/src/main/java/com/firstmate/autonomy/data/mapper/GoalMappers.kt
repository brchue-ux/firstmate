package com.firstmate.autonomy.data.mapper

import com.firstmate.autonomy.data.local.entity.GoalEntity
import com.firstmate.autonomy.data.local.entity.MomentEntity
import com.firstmate.autonomy.data.local.entity.ParticularEntity
import com.firstmate.autonomy.data.local.relation.GoalWithParticulars
import com.firstmate.autonomy.data.local.relation.ParticularWithHistory
import com.firstmate.autonomy.domain.model.Goal
import com.firstmate.autonomy.domain.model.Moment
import com.firstmate.autonomy.domain.model.Particular

/**
 * Storage rows in, domain types out.
 *
 * The domain layer knows nothing about Room, so every field it reads is
 * assembled here rather than annotated onto a model the rest of the app shares
 * with the database.
 */
fun GoalWithParticulars.toDomain(): Goal = Goal(
    id = goal.id,
    title = goal.title,
    category = goal.category,
    status = goal.status,
    notes = goal.notes,
    position = goal.position,
    createdAt = goal.createdAt,
    particulars = particulars
        .sortedWith(compareBy({ it.particular.position }, { it.particular.id }))
        .map { it.toDomain() },
)

fun ParticularWithHistory.toDomain(): Particular = Particular(
    id = particular.id,
    goalId = particular.goalId,
    title = particular.title,
    kind = particular.kind,
    notes = particular.notes,
    position = particular.position,
    checkInDays = checkIns.mapTo(mutableSetOf()) { it.date },
    moments = moments.map { it.toDomain() }.sortedByDescending { it.date },
)

fun MomentEntity.toDomain(): Moment = Moment(
    id = id,
    particularId = particularId,
    label = label,
    date = date,
    note = note,
)

fun Goal.toEntity(updatedAtMillis: java.time.Instant): GoalEntity = GoalEntity(
    id = id,
    title = title,
    category = category,
    status = status,
    notes = notes,
    position = position,
    createdAt = createdAt,
    updatedAt = updatedAtMillis,
)

fun Particular.toEntity(createdAt: java.time.Instant): ParticularEntity = ParticularEntity(
    id = id,
    goalId = goalId,
    title = title,
    kind = kind,
    notes = notes,
    position = position,
    createdAt = createdAt,
)
