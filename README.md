# Claude Code Plugins Directory

A curated directory of plugins for Claude Code.

> **⚠️ Important:** Make sure you trust a plugin before installing, updating, or using it. This directory does not control what MCP servers, files, or other software are included in plugins and cannot verify that they will work as intended or that they won't change. See each plugin's homepage for more information.

## Installation

Plugins can be installed directly from this marketplace via Claude Code's plugin system.

To install, run:
```
/plugin install {plugin-name}@stilero
```

or browse for the plugin in `/plugin > Discover`

## Plugin Structure

Each plugin follows a standard structure:

```
plugin-name/
├── .claude-plugin/
│   └── plugin.json          # Plugin metadata (required)
├── .mcp.json                # MCP server configuration (optional)
├── commands/                # Slash commands (optional)
├── agents/                  # Agent definitions (optional)
├── skills/                  # Skill definitions (optional)
└── README.md                # Documentation
```

## Documentation

For more information on developing Claude Code plugins, see the [official documentation](https://code.claude.com/docs/en/plugins).
