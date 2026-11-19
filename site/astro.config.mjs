// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { site } from './site.config.ts';

export default defineConfig({
  // Placeholder domain (RFC 2606 reserved TLD). The owner sets the real domain
  // here at go-live; it only affects canonical URLs, sitemap and OG image URLs.
  site: 'https://brahma.invalid',
  integrations: [
    starlight({
      title: site.title,
      description: site.description,
      customCss: ['./src/styles/tokens.css'],
      sidebar: [
        { label: 'Using Brahma', items: [{ autogenerate: { directory: 'docs' } }] },
        { label: 'Inside Brahma', items: [{ autogenerate: { directory: 'internals' } }] },
        { label: 'API reference', link: `${site.apiBase}/` },
      ],
      // The 404 page is src/content/docs/404.md, rendered by the regular docs
      // route; Starlight's built-in /404 route would conflict with it.
      disable404Route: true,
      pagefind: true,
      lastUpdated: false,
      credits: false,
      // Social links are added once site.repoURL is set (public repository).
      social: [],
      components: {},
    }),
  ],
});
