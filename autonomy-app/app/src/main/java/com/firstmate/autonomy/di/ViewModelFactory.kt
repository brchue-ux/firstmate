package com.firstmate.autonomy.di

import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewmodel.CreationExtras
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.firstmate.autonomy.AutonomyApplication
import com.firstmate.autonomy.ui.dashboard.DashboardViewModel
import com.firstmate.autonomy.ui.decisions.DecisionEditorViewModel
import com.firstmate.autonomy.ui.decisions.DecisionListViewModel
import com.firstmate.autonomy.ui.domains.DomainDetailViewModel
import com.firstmate.autonomy.ui.domains.DomainEditorViewModel
import com.firstmate.autonomy.ui.domains.DomainListViewModel
import com.firstmate.autonomy.ui.habits.HabitViewModel

/**
 * One factory for every ViewModel in the app.
 *
 * Each initializer pulls what it needs out of the [AppContainer], so ViewModels
 * keep plain constructors and stay unit-testable without any Android plumbing.
 */
object AutonomyViewModelFactory {

    val Factory = viewModelFactory {
        initializer {
            DashboardViewModel(
                getDashboardOverview = container().getDashboardOverview,
                habitRepository = container().habitRepository,
                clock = container().clock,
            )
        }
        initializer {
            DomainListViewModel(domainRepository = container().domainRepository)
        }
        initializer {
            DomainDetailViewModel(
                savedStateHandle = createSavedStateHandle(),
                domainRepository = container().domainRepository,
            )
        }
        initializer {
            DomainEditorViewModel(
                savedStateHandle = createSavedStateHandle(),
                domainRepository = container().domainRepository,
            )
        }
        initializer {
            DecisionListViewModel(decisionRepository = container().decisionRepository)
        }
        initializer {
            DecisionEditorViewModel(
                savedStateHandle = createSavedStateHandle(),
                decisionRepository = container().decisionRepository,
                clock = container().clock,
            )
        }
        initializer {
            HabitViewModel(
                habitRepository = container().habitRepository,
                getHabitConsistency = container().getHabitConsistency,
                clock = container().clock,
            )
        }
    }

    private fun CreationExtras.container(): AppContainer =
        (this[APPLICATION_KEY] as AutonomyApplication).container
}
