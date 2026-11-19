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
      // Order matters: tokens → faces/type → Starlight remap → motion. Unlayered, so
      // these rules beat Starlight's cascade layers.
      customCss: [
        './src/styles/tokens.css',
        './src/styles/typography.css',
        './src/styles/starlight.css',
        './src/styles/motion.css',
      ],
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
      components: {
        Head: './src/components/SiteHead.astro',
        Footer: './src/components/SiteFooter.astro',
        // Dark only: no theme toggle, and no inline script flipping `data-theme`
        // to the OS preference.
        ThemeSelect: './src/components/Empty.astro',
        ThemeProvider: './src/components/Empty.astro',
      },
    }),
  ],
});
