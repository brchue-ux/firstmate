package com.firstmate.autonomy.data.mapper

import com.firstmate.autonomy.data.local.entity.DecisionEntity
import com.firstmate.autonomy.domain.model.Decision

/**
 * Storage rows to domain models.
 *
 * These stayed after TypeConverters took over the primitive marshalling,
 * because the boundary they defend is architectural rather than mechanical:
 * domain models carry no Room annotations, so nothing above `data/` can end up
 * depending on the persistence framework.
 */

fun DecisionEntity.toDomainModel(): Decision = Decision(
    id = id,
    title = title,
    date = date,
    category = category,
    myPreference = myPreference,
    finalChoice = finalChoice,
    reflection = reflection,
    createdAt = createdAt,
    goalId = goalId,
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
    goalId = goalId,
)
