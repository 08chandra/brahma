// Site-wide settings shared by astro.config.mjs, pages and components.
// Later tasks import these names; keep them stable.
export const site = {
  title: 'Brahma',
  description:
    'Run a company of sandboxed AI agents on your Mac. A native macOS app and a brahma CLI over one engine.',
  // Public repository URL. Empty until the repository is public; components
  // that link to source or show a GitHub icon are gated on this being non-empty.
  repoURL: '' as string,
  // Base path of the generated API reference (DocC output). Set to a full URL
  // if the API reference is deployed as a separate project.
  apiBase: '/api' as string,
  license: 'Apache-2.0',
};
