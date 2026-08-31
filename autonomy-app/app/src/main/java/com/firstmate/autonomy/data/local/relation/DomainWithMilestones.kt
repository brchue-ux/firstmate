package com.firstmate.autonomy.data.local.relation

import androidx.room.Embedded
import androidx.room.Relation
import com.firstmate.autonomy.data.local.entity.DomainEntity
import com.firstmate.autonomy.data.local.entity.MilestoneEntity

/** A domain row joined with its milestone rows in a single observed query. */
data class DomainWithMilestones(
    @Embedded val domain: DomainEntity,
    @Relation(parentColumn = "id", entityColumn = "domain_id")
    val milestones: List<MilestoneEntity>,
)
