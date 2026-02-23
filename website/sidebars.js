/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docsSidebar: [
    'intro',
    'architecture',
    {
      type: 'category',
      label: 'Core',
      collapsed: false,
      items: [
        'core/schema',
        'core/store',
        'core/graph',
        'core/runtime',
      ],
    },
    {
      type: 'category',
      label: 'DSL',
      collapsed: false,
      items: [
        'dsl/overview',
        'dsl/model-turn',
        'dsl/patching',
      ],
    },
    {
      type: 'category',
      label: 'Features',
      collapsed: false,
      items: [
        'features/checkpointing',
        'features/interrupt-resume',
        'features/hybrid-inference',
        'features/memory',
      ],
    },
    {
      type: 'category',
      label: 'Ecosystem',
      items: [
        'ecosystem/adapters',
        'ecosystem/data-structures',
      ],
    },
    {
      type: 'category',
      label: 'Guides',
      items: [
        'guides/installation',
        'guides/error-handling',
        'guides/testing',
        'guides/examples',
      ],
    },
  ],
};

module.exports = sidebars;
