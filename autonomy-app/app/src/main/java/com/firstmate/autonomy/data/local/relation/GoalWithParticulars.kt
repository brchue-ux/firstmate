package com.firstmate.autonomy.data.local.relation

import androidx.room.Embedded
import androidx.room.Relation
import com.firstmate.autonomy.data.local.entity.CheckInEntity
import com.firstmate.autonomy.data.local.entity.GoalEntity
import com.firstmate.autonomy.data.local.entity.MomentEntity
import com.firstmate.autonomy.data.local.entity.ParticularEntity

/** A particular together with everything that hangs off it. */
data class ParticularWithHistory(
    @Embedded val particular: ParticularEntity,
    @Relation(parentColumn = "id", entityColumn = "particular_id")
    val checkIns: List<CheckInEntity>,
    @Relation(parentColumn = "id", entityColumn = "particular_id")
    val moments: List<MomentEntity>,
)

/**
 * A whole goal in one read.
 *
 * The space view draws every goal at once, so fetching particulars and their
 * history per goal would mean a query per galaxy on every frame's data update.
 * Room resolves this in three queries total regardless of how many goals exist.
 */
data class GoalWithParticulars(
    @Embedded val goal: GoalEntity,
    @Relation(
        entity = ParticularEntity::class,
        parentColumn = "id",
        entityColumn = "goal_id",
    )
    val particulars: List<ParticularWithHistory>,
)
