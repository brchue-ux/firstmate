package com.firstmate.autonomy.domain.repository

import kotlinx.coroutines.flow.Flow

/**
 * The handful of local preferences the app keeps.
 *
 * Declared here rather than only as the DataStore-backed class, because the
 * domain layer must not reach into `data/`: a use case that imported the
 * concrete repository would drag an Android Context into the one layer that
 * is meant to be free of the framework.
 */
interface SettingsRepository {

    val celebrationsEnabled: Flow<Boolean>

    suspend fun setCelebrationsEnabled(enabled: Boolean)

    /**
     * Whether the starter goals have been offered.
     *
     * A flag rather than an "is the database empty" check, so deleting every
     * starter goal is respected instead of being undone on the next launch.
     */
    suspend fun starterGoalsSeeded(): Boolean

    suspend fun markStarterGoalsSeeded()
}
