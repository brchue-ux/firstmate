package com.firstmate.autonomy.domain.usecase

import com.firstmate.autonomy.domain.repository.SettingsRepository
import com.firstmate.autonomy.domain.model.SurfaceKind
import com.firstmate.autonomy.domain.repository.GoalRepository
import kotlinx.coroutines.flow.first
import javax.inject.Inject

/**
 * Puts a starting set of goals in the sky, once.
 *
 * Opening onto an empty void is a bad first minute: there is nothing to look
 * at and nothing to tap, and the shape of the app - goals as galaxies,
 * particulars as the planets you tick - cannot be understood from a blank
 * screen. These are deliberately broad, because they are meant to be renamed
 * into whatever the person actually does.
 *
 * Two rules keep this from being destructive. It runs at most once, recorded
 * by a flag rather than by "is the database empty", so deleting every starter
 * is respected instead of being undone on the next launch. And it adds only
 * titles that are not already there, so goals entered by hand are never
 * duplicated.
 *
 * Nothing is ticked. Every starter therefore opens frozen, which is the truth:
 * no days have been logged against it yet, and it warms as they are.
 */
class SeedStarterGoalsUseCase @Inject constructor(
    private val goalRepository: GoalRepository,
    private val settings: SettingsRepository,
) {
    suspend operator fun invoke() {
        if (settings.starterGoalsSeeded()) return

        val existing = goalRepository.observeGoals().first()
            .mapTo(mutableSetOf()) { it.title.trim().lowercase() }

        STARTERS.forEach { starter ->
            if (starter.title.lowercase() in existing) return@forEach
            val goalId = goalRepository.createGoal(
                title = starter.title,
                category = starter.category,
                notes = starter.notes,
            )
            starter.particulars.forEach { (title, kind) ->
                goalRepository.addParticular(goalId, title, kind, "")
            }
        }
        settings.markStarterGoalsSeeded()
    }

    private data class Starter(
        val title: String,
        val category: String,
        val notes: String,
        val particulars: List<Pair<String, SurfaceKind>>,
    )

    private companion object {
        val STARTERS = listOf(
            Starter(
                "Mental health", "Health",
                "The things that keep the week survivable. Rename these to what actually works for you.",
                listOf(
                    "Sleep" to SurfaceKind.ICE,
                    "Time outside" to SurfaceKind.OCEAN,
                    "Away from the screen" to SurfaceKind.BASALT,
                    "Talk to someone" to SurfaceKind.CLOUD,
                ),
            ),
            Starter(
                "Physical health", "Health",
                "Movement and food. Three of these will matter more than four.",
                listOf(
                    "Strength" to SurfaceKind.EMBER,
                    "Cardio" to SurfaceKind.ROCK,
                    "Stretching" to SurfaceKind.DESERT,
                    "Eating properly" to SurfaceKind.OCEAN,
                ),
            ),
            Starter(
                "Piano practice", "Craft",
                "",
                listOf(
                    "Scales" to SurfaceKind.DESERT,
                    "Passages" to SurfaceKind.ROCK,
                    "Sight reading" to SurfaceKind.ICE,
                    "Playing for someone" to SurfaceKind.BASALT,
                ),
            ),
            Starter(
                "Basement renovation", "Home",
                "",
                listOf(
                    "Framing" to SurfaceKind.ROCK,
                    "Wiring" to SurfaceKind.EMBER,
                    "Insulation" to SurfaceKind.BASALT,
                    "Drywall" to SurfaceKind.DESERT,
                ),
            ),
            Starter(
                "Reading", "Craft",
                "",
                listOf(
                    "Fiction" to SurfaceKind.OCEAN,
                    "Something harder" to SurfaceKind.ICE,
                ),
            ),
            Starter(
                "Cooking", "Home",
                "",
                listOf(
                    "Cook from scratch" to SurfaceKind.EMBER,
                    "Plan the week" to SurfaceKind.DESERT,
                ),
            ),
            Starter(
                "Money", "Life",
                "",
                listOf(
                    "Track what went out" to SurfaceKind.BASALT,
                    "Put something aside" to SurfaceKind.GAS,
                ),
            ),
            Starter(
                "People", "Life",
                "The ones that go quiet first when everything else gets busy.",
                listOf(
                    "Family" to SurfaceKind.OCEAN,
                    "Friends" to SurfaceKind.CLOUD,
                ),
            ),
            Starter(
                "Learning something new", "Craft",
                "",
                listOf(
                    "Study it" to SurfaceKind.DESERT,
                    "Actually use it" to SurfaceKind.ROCK,
                ),
            ),
        )
    }
}
