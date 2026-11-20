// Starlight route middleware (configured as `routeMiddleware` in astro.config.mjs).
// Shows the generated CLI reference (docs/cli/) as a collapsed "CLI reference"
// group under "Using Brahma"; see src/sidebar-groups.mjs.
import { defineRouteMiddleware } from '@astrojs/starlight/route-data';
import { GROUP_LABELS, relabelGroups } from './sidebar-groups.mjs';

export const onRequest = defineRouteMiddleware((context) => {
  relabelGroups(context.locals.starlightRoute.sidebar, GROUP_LABELS);
});
