package com.firstmate.autonomy.data.preferences

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.preferencesDataStore
import com.firstmate.autonomy.domain.repository.SettingsRepository
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

private val Context.settingsDataStore: DataStore<Preferences> by preferencesDataStore(
    name = "autonomy_settings",
)

/**
 * User settings that are genuinely key-value.
 *
 * These live in Preferences DataStore rather than Room on purpose. They have no
 * relations, are never queried or sorted, and are read as a whole on every
 * launch - so a table, a DAO and a migration path would all be overhead. See
 * `docs/storage-choices.md` for the full comparison.
 *
 * A read failure degrades to defaults rather than propagating: a corrupt
 * settings file should never stop the app from opening.
 */
@Singleton
class SettingsRepositoryImpl @Inject constructor(
    @ApplicationContext private val context: Context,
) : SettingsRepository {
    private object Keys {
        val CELEBRATIONS_ENABLED = booleanPreferencesKey("celebrations_enabled")
        val STARTER_GOALS_SEEDED = booleanPreferencesKey("starter_goals_seeded")
    }

    override val celebrationsEnabled: Flow<Boolean> = context.settingsDataStore.data
        .catch { throwable ->
            if (throwable is IOException) emit(emptyPreferences()) else throw throwable
        }
        .map { it[Keys.CELEBRATIONS_ENABLED] ?: true }

    override suspend fun setCelebrationsEnabled(enabled: Boolean) {
        context.settingsDataStore.edit { it[Keys.CELEBRATIONS_ENABLED] = enabled }
    }

    override suspend fun starterGoalsSeeded(): Boolean =
        context.settingsDataStore.data
            .catch { throwable ->
                if (throwable is IOException) emit(emptyPreferences()) else throw throwable
            }
            .first()[Keys.STARTER_GOALS_SEEDED] ?: false

    override suspend fun markStarterGoalsSeeded() {
        context.settingsDataStore.edit { it[Keys.STARTER_GOALS_SEEDED] = true }
    }
}
