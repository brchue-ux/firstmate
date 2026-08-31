package com.firstmate.autonomy.ui.navigation

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.firstmate.autonomy.ui.dashboard.DashboardScreen
import com.firstmate.autonomy.ui.decisions.DecisionEditorScreen
import com.firstmate.autonomy.ui.decisions.DecisionListScreen
import com.firstmate.autonomy.ui.domains.DomainDetailScreen
import com.firstmate.autonomy.ui.domains.DomainEditorScreen
import com.firstmate.autonomy.ui.domains.DomainListScreen
import com.firstmate.autonomy.ui.habits.HabitScreen

/**
 * App shell: a bottom bar over a single [NavHost].
 *
 * The bar is hidden on detail and editor routes so those screens read as a
 * focused push rather than another tab.
 */
@Composable
fun AutonomyApp(
    modifier: Modifier = Modifier,
    navController: NavHostController = rememberNavController(),
) {
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = backStackEntry?.destination
    val isTopLevel = currentDestination?.hierarchy?.any { destination ->
        TopLevelDestination.entries.any { it.route == destination.route }
    } == true

    Scaffold(
        modifier = modifier.fillMaxSize(),
        bottomBar = {
            if (isTopLevel) {
                NavigationBar {
                    TopLevelDestination.entries.forEach { destination ->
                        val selected = currentDestination
                            ?.hierarchy
                            ?.any { it.route == destination.route } == true
                        NavigationBarItem(
                            selected = selected,
                            onClick = { navController.navigateToTopLevel(destination) },
                            icon = {
                                Icon(
                                    imageVector = if (selected) {
                                        destination.selectedIcon
                                    } else {
                                        destination.unselectedIcon
                                    },
                                    contentDescription = null,
                                )
                            },
                            label = { Text(destination.label) },
                        )
                    }
                }
            }
        },
    ) { innerPadding ->
        AutonomyNavHost(
            navController = navController,
            modifier = Modifier.padding(innerPadding),
        )
    }
}

@Composable
private fun AutonomyNavHost(
    navController: NavHostController,
    modifier: Modifier = Modifier,
) {
    NavHost(
        navController = navController,
        startDestination = Routes.DASHBOARD,
        modifier = modifier,
    ) {
        composable(Routes.DASHBOARD) {
            DashboardScreen(
                onNewProject = { navController.navigate(Routes.domainEditor()) },
                onLogDecision = { navController.navigate(Routes.decisionEditor()) },
                onDailyCheckIn = {
                    navController.navigateToTopLevel(TopLevelDestination.HABITS)
                },
                onDomainClick = { navController.navigate(Routes.domainDetail(it)) },
                onSeeAllDomains = {
                    navController.navigateToTopLevel(TopLevelDestination.DOMAINS)
                },
                onSeeAllDecisions = {
                    navController.navigateToTopLevel(TopLevelDestination.DECISIONS)
                },
                onDecisionClick = { navController.navigate(Routes.decisionEditor(it)) },
            )
        }

        composable(Routes.DOMAIN_LIST) {
            DomainListScreen(
                onDomainClick = { navController.navigate(Routes.domainDetail(it)) },
                onCreateDomain = { navController.navigate(Routes.domainEditor()) },
            )
        }

        composable(
            route = Routes.DOMAIN_DETAIL,
            arguments = listOf(navArgument(ARG_DOMAIN_ID) { type = NavType.LongType }),
        ) {
            DomainDetailScreen(
                onNavigateBack = { navController.popBackStack() },
                onEditDomain = { navController.navigate(Routes.domainEditor(it)) },
            )
        }

        composable(
            route = Routes.DOMAIN_EDITOR,
            arguments = listOf(
                navArgument(ARG_DOMAIN_ID) {
                    type = NavType.LongType
                    defaultValue = NO_ID
                },
            ),
        ) {
            DomainEditorScreen(onNavigateBack = { navController.popBackStack() })
        }

        composable(Routes.DECISION_LIST) {
            DecisionListScreen(
                onDecisionClick = { navController.navigate(Routes.decisionEditor(it)) },
                onCreateDecision = { navController.navigate(Routes.decisionEditor()) },
            )
        }

        composable(
            route = Routes.DECISION_EDITOR,
            arguments = listOf(
                navArgument(ARG_DECISION_ID) {
                    type = NavType.LongType
                    defaultValue = NO_ID
                },
            ),
        ) {
            DecisionEditorScreen(onNavigateBack = { navController.popBackStack() })
        }

        composable(Routes.HABITS) {
            HabitScreen()
        }
    }
}

/**
 * Tab switching: single top, state preserved per tab, and the back stack
 * always unwinds to the dashboard rather than through every tab visited.
 */
private fun NavHostController.navigateToTopLevel(destination: TopLevelDestination) {
    navigate(destination.route) {
        popUpTo(graph.findStartDestination().id) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}
