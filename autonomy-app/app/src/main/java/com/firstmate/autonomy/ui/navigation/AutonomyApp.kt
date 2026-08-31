package com.firstmate.autonomy.ui.navigation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
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
 * The bar slides away on detail and editor routes rather than disappearing,
 * so a push reads as going deeper rather than as the chrome glitching.
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
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = {
            AnimatedVisibility(
                visible = isTopLevel,
                enter = slideInVertically(tween(240)) { it },
                exit = slideOutVertically(tween(200)) { it },
            ) {
                NavigationBar(
                    containerColor = MaterialTheme.colorScheme.surfaceContainer,
                ) {
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
                            colors = NavigationBarItemDefaults.colors(
                                selectedIconColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                selectedTextColor = MaterialTheme.colorScheme.primary,
                                indicatorColor = MaterialTheme.colorScheme.primaryContainer,
                                unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                                unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            ),
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
        // Tabs cross-fade; the push/pop pairs below override this per route.
        enterTransition = { tabEnter() },
        exitTransition = { tabExit() },
        popEnterTransition = { tabEnter() },
        popExitTransition = { tabExit() },
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
            enterTransition = { pushEnter() },
            exitTransition = { pushExit() },
            popEnterTransition = { popEnter() },
            popExitTransition = { popExit() },
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
            enterTransition = { pushEnter() },
            exitTransition = { pushExit() },
            popEnterTransition = { popEnter() },
            popExitTransition = { popExit() },
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
            enterTransition = { pushEnter() },
            exitTransition = { pushExit() },
            popEnterTransition = { popEnter() },
            popExitTransition = { popExit() },
        ) {
            DecisionEditorScreen(onNavigateBack = { navController.popBackStack() })
        }

        composable(Routes.HABITS) {
            HabitScreen()
        }
    }
}

/**
 * Tab switching: single top, state preserved per tab, and the back stack always
 * unwinds to the dashboard rather than through every tab visited.
 */
private fun NavHostController.navigateToTopLevel(destination: TopLevelDestination) {
    navigate(destination.route) {
        popUpTo(graph.findStartDestination().id) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}
