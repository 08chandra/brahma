import { defineCollection } from 'astro:content';
import { docsLoader, i18nLoader } from '@astrojs/starlight/loaders';
import { docsSchema, i18nSchema } from '@astrojs/starlight/schema';

export const collections = {
  docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }),
  // Starlight looks this collection up for UI string overrides. It is defined
  // with one (empty) English entry so the lookup does not warn at build time.
  i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema() }),
};
