# API Versions & Migration Guide

This reference covers Shopify API versioning, current best practices, and migration strategies.

## Current API Versions (as of 2024)

Shopify releases new API versions quarterly. Always use the latest stable version for new apps.

**Recommended version**: `2024-01` or newer

**Version format**: `YYYY-MM` (e.g., `2024-01`, `2024-04`, `2024-07`, `2024-10`)

**Support period**: Each API version is supported for a minimum of 12 months from release date.

## API Version Configuration

### In shopify.app.toml

```toml
[build]
api_version = "2024-01"
```

### In Code (GraphQL Admin API)

```javascript
// Shopify CLI templates handle this automatically
const response = await admin.graphql(query);

// For manual clients
const SHOPIFY_API_VERSION = '2024-01';
const endpoint = `https://${shop}/admin/api/${SHOPIFY_API_VERSION}/graphql.json`;
```

### In Code (REST Admin API)

```javascript
const response = await fetch(
  `https://${shop}/admin/api/2024-01/products.json`,
  {
    headers: {
      'X-Shopify-Access-Token': accessToken,
    },
  }
);
```

### Storefront API

```javascript
const STOREFRONT_API_VERSION = '2024-01';
const endpoint = `https://${shop}/api/${STOREFRONT_API_VERSION}/graphql.json`;
```

## Version Selection Strategy

### For New Apps
- Use the **latest stable version** (2024-01 or newer)
- Avoids deprecated features from the start
- Access to newest functionality

### For Existing Apps
- Test against new versions in development stores
- Review release notes for breaking changes
- Plan migrations during low-traffic periods
- Use feature flags for gradual rollouts

## Breaking Changes to Watch For

### Common Breaking Changes Between Versions

1. **Field Removals/Deprecations**
   - GraphQL fields marked deprecated in one version may be removed in future versions
   - Always check `deprecationReason` in schema

2. **Type Changes**
   - Scalar types changing (String → ID, Int → Float)
   - Nullable fields becoming non-nullable (or vice versa)

3. **Argument Requirements**
   - Optional arguments becoming required
   - New required fields in input types

4. **Behavior Changes**
   - Rate limit calculations
   - Permission requirements
   - Default values

## Migration Checklist

### Pre-Migration

- [ ] Review release notes for target version
- [ ] Identify deprecated fields in current queries
- [ ] Test all GraphQL queries in GraphiQL with new version
- [ ] Check webhook payload changes
- [ ] Update test suite to verify against new version

### Migration Steps

1. **Update Configuration**
   ```toml
   # shopify.app.toml
   api_version = "2024-XX"  # New version
   ```

2. **Update Code**
   - Replace deprecated fields with alternatives
   - Add new required arguments
   - Handle new error types
   - Update type definitions

3. **Test Thoroughly**
   - Run full test suite
   - Manual testing in development store
   - Verify webhook handlers
   - Check error handling paths

4. **Deploy Gradually**
   - Deploy to staging environment
   - Monitor error rates and logs
   - Gradual rollout to production
   - Have rollback plan ready

### Post-Migration

- [ ] Monitor error rates for 48 hours
- [ ] Check for unexpected API behavior
- [ ] Update documentation
- [ ] Remove deprecated code paths

## GraphQL Schema Introspection

Check for deprecations and changes:

```javascript
// Query for deprecated fields
const introspectionQuery = `
  query IntrospectionQuery {
    __schema {
      types {
        name
        fields(includeDeprecated: true) {
          name
          isDeprecated
          deprecationReason
        }
      }
    }
  }
`;

const response = await admin.graphql(introspectionQuery);
const schema = await response.json();

// Find deprecated fields in use
const deprecatedFields = schema.data.__schema.types
  .flatMap(type => type.fields || [])
  .filter(field => field.isDeprecated);
```

## API Version Detection

```javascript
// Detect which version a shop is using
async function detectApiVersion(admin) {
  try {
    // Try a query that differs between versions
    const response = await admin.graphql(`
      query {
        shop {
          id
          features {  # This field changes between versions
            storefront
          }
        }
      }
    `);
    
    const data = await response.json();
    
    if (data.errors) {
      // Field doesn't exist - older version
      return 'pre-2024-01';
    }
    
    return 'current';
  } catch (error) {
    console.error('Version detection failed:', error);
    return 'unknown';
  }
}
```

## Handling Multiple API Versions

For apps supporting multiple merchant API versions:

```javascript
class VersionAwareClient {
  constructor(admin, version) {
    this.admin = admin;
    this.version = version;
  }

  async getProducts() {
    // Version-specific query selection
    const query = this.version >= '2024-01'
      ? this.getProductsQuery_2024_01()
      : this.getProductsQuery_Legacy();
    
    return await this.admin.graphql(query);
  }

  getProductsQuery_2024_01() {
    return `#graphql
      query {
        products(first: 10) {
          edges {
            node {
              id
              title
              category {  # New in 2024-01
                name
              }
            }
          }
        }
      }
    `;
  }

  getProductsQuery_Legacy() {
    return `#graphql
      query {
        products(first: 10) {
          edges {
            node {
              id
              title
              productType  # Deprecated in 2024-01
            }
          }
        }
      }
    `;
  }
}
```

## Webhook API Versions

Webhooks also follow API versioning:

```javascript
// Configure webhook with specific version
await shopify.webhooks.addHandlers({
  PRODUCTS_CREATE: {
    deliveryMethod: DeliveryMethod.Http,
    callbackUrl: '/webhooks/products/create',
    includeFields: ['id', 'title'],
    metafieldNamespaces: ['custom'],
    // Version is inherited from app configuration
  },
});

// Webhook payload will match configured API version
export async function action({ request }) {
  const { topic, shop, payload, apiVersion } = await authenticate.webhook(request);
  
  console.log(`Webhook received for API version: ${apiVersion}`);
  
  // Handle payload according to version
  if (apiVersion >= '2024-01') {
    // Use new payload structure
  } else {
    // Use legacy payload structure
  }
}
```

## Deprecation Warnings

Monitor deprecation warnings in responses:

```javascript
async function queryWithDeprecationCheck(admin, query) {
  const response = await admin.graphql(query);
  const data = await response.json();
  
  // Check for deprecation warnings in extensions
  if (data.extensions?.cost?.deprecations) {
    console.warn('Deprecated fields used:', data.extensions.cost.deprecations);
    
    // Log to monitoring service
    await logDeprecationWarning({
      query,
      deprecations: data.extensions.cost.deprecations,
    });
  }
  
  return data;
}
```

## Version Upgrade Timeline

### Typical Shopify API Lifecycle

1. **Release** (Month 0)
   - New version announced
   - Available for testing

2. **Stable** (Month 1-9)
   - Recommended for production use
   - No breaking changes within version

3. **Deprecation Notice** (Month 9-12)
   - Advance notice of upcoming removal
   - Migration guides published

4. **Sunset** (Month 12+)
   - Version no longer supported
   - Apps must upgrade

### Planning Upgrade Cycles

```javascript
// Track version upgrade schedule
const versionSchedule = {
  current: '2024-01',
  deprecationDate: new Date('2025-01-01'),
  sunsetDate: new Date('2025-04-01'),
  nextVersion: '2024-04',
};

// Alert when approaching deprecation
function checkVersionStatus() {
  const now = new Date();
  const daysUntilDeprecation = Math.floor(
    (versionSchedule.deprecationDate - now) / (1000 * 60 * 60 * 24)
  );
  
  if (daysUntilDeprecation < 90) {
    console.warn(`API version ${versionSchedule.current} will be deprecated in ${daysUntilDeprecation} days`);
    // Send alert to team
  }
}
```

## Resources

- **API Release Notes**: https://shopify.dev/docs/api/release-notes
- **GraphQL Admin API**: https://shopify.dev/docs/api/admin-graphql
- **Storefront API**: https://shopify.dev/docs/api/storefront
- **API Versioning Guide**: https://shopify.dev/docs/api/usage/versioning

Use the Shopify Dev MCP server to access the latest documentation and migration guides when planning version upgrades.