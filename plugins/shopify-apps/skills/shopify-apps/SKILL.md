---
name: shopify-apps
description: Expert guidance for building Shopify Apps using modern best practices. Use when developing Shopify Apps, creating app extensions, working with Shopify APIs (GraphQL Admin/Storefront), implementing webhooks, managing app authentication/authorization, building embedded apps, creating custom app extensions (checkout UI, product subscription, theme extensions), or any Shopify app development task. Assumes Shopify Dev MCP server is available at https://shopify.dev/docs/apps/build/devmcp for accessing Shopify's development resources and documentation.
---

# Shopify Apps Development

Expert guidance for building Shopify Apps with modern architecture, authentication patterns, and best practices based on current Shopify documentation.

## Core Capabilities

This skill provides expertise in:

1. **App Architecture & Setup** - Initialize apps, configure authentication, set up development environment
2. **GraphQL API Integration** - Admin API and Storefront API queries/mutations with proper patterns
3. **App Extensions** - Build checkout UI extensions, theme extensions, product subscriptions, POS UI extensions
4. **Embedded App UI** - Create embedded admin interfaces using App Bridge and Polaris
5. **Webhooks & Events** - Implement webhook handlers, manage event subscriptions
6. **App Distribution** - Prepare apps for submission, handle billing, manage app listings

## Prerequisites & MCP Integration

**Shopify Dev MCP Server**: This skill assumes the Shopify Dev MCP server is available and connected. The MCP server provides:
- Access to latest Shopify documentation at https://shopify.dev
- Up-to-date API references and examples
- Current best practices and patterns

When documentation is needed, use the MCP server to fetch the latest information from Shopify's official docs.

## Quick Start Workflows

### Creating a New Shopify App

1. **Choose your stack**: Remix (recommended), Next.js, or other Node.js framework
2. **Initialize with Shopify CLI**:
   ```bash
   npm init @shopify/app@latest
   # or
   shopify app init
   ```
3. **Configure OAuth scopes** in `shopify.app.toml`
4. **Set up database** for storing session tokens and app data
5. **Deploy** to a publicly accessible URL (required for OAuth)

### Authentication Flow

Modern Shopify apps use **Session Tokens** (for embedded apps) and **OAuth** (for authorization):

```javascript
// Session token validation (embedded apps)
import { authenticate } from './shopify.server';

export async function loader({ request }) {
  const { session, admin } = await authenticate.admin(request);
  // session contains shop, accessToken, etc.
}

// OAuth installation flow
// Handled automatically by Shopify App Remix/CLI templates
```

**Key principles**:
- Store access tokens securely per shop
- Use session tokens for embedded app requests
- Validate all requests from Shopify
- Handle token expiration gracefully

### GraphQL Query Patterns

**Admin API queries** (for app backend):

```javascript
const response = await admin.graphql(
  `#graphql
    query getProducts($first: Int!) {
      products(first: $first) {
        edges {
          node {
            id
            title
            handle
            status
          }
        }
      }
    }`,
  { variables: { first: 10 } }
);

const data = await response.json();
```

**Storefront API queries** (for customer-facing features):

```javascript
const response = await fetch(`https://${shop}/api/2024-01/graphql.json`, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'X-Shopify-Storefront-Access-Token': storefrontAccessToken,
  },
  body: JSON.stringify({ query, variables }),
});
```

**Best practices**:
- Use query cost analysis to avoid rate limits
- Implement pagination for large datasets
- Batch operations when possible
- Cache responses appropriately

## App Extensions Development

### Checkout UI Extensions

Build custom UI in checkout flow:

```javascript
// extensions/checkout-ui/src/Checkout.jsx
import {
  reactExtension,
  useApi,
  Banner,
} from '@shopify/ui-extensions-react/checkout';

export default reactExtension(
  'purchase.checkout.block.render',
  () => <Extension />
);

function Extension() {
  const { cost } = useApi();
  
  return (
    <Banner status="info">
      Your order total: {cost.totalAmount.amount}
    </Banner>
  );
}
```

**Extension targets**:
- `purchase.checkout.block.render` - Checkout page
- `purchase.checkout.cart-line-item.render-after` - After cart items
- `purchase.thank-you.block.render` - Thank you page

### Theme App Extensions

Inject app functionality into themes:

```liquid
{% comment %} extensions/theme-extension/blocks/app-block.liquid {% endcomment %}
<div class="app-block" {{ block.shopify_attributes }}>
  <h3>{{ block.settings.heading }}</h3>
  <p>{{ block.settings.description }}</p>
</div>

{% schema %}
{
  "name": "App Block",
  "target": "section",
  "settings": [
    {
      "type": "text",
      "id": "heading",
      "label": "Heading"
    }
  ]
}
{% endschema %}
```

### Product Subscription Extensions

Enable subscription functionality:

```javascript
// Configure subscription plans
const subscriptionPlan = {
  name: "Monthly subscription",
  options: {
    deliveryPolicy: {
      interval: "MONTH",
      intervalCount: 1
    },
    pricingPolicy: {
      percentage: 10 // 10% discount
    }
  }
};
```

## Embedded App UI with App Bridge

**Initialize App Bridge**:

```javascript
import createApp from '@shopify/app-bridge';

const app = createApp({
  apiKey: process.env.SHOPIFY_API_KEY,
  host: new URLSearchParams(location.search).get('host'),
});
```

**Use Polaris components** for consistent UI:

```jsx
import { Page, Card, Button } from '@shopify/polaris';

function AppPage() {
  return (
    <Page title="Dashboard">
      <Card sectioned>
        <Button primary>Save</Button>
      </Card>
    </Page>
  );
}
```

**Navigation**:

```javascript
import { Redirect } from '@shopify/app-bridge/actions';

const redirect = Redirect.create(app);
redirect.dispatch(Redirect.Action.ADMIN_PATH, '/products');
```

## Webhook Implementation

**Register webhooks**:

```javascript
// shopify.server.js or similar
await shopify.webhooks.addHandlers({
  PRODUCTS_CREATE: {
    deliveryMethod: DeliveryMethod.Http,
    callbackUrl: '/webhooks/products/create',
  },
  ORDERS_PAID: {
    deliveryMethod: DeliveryMethod.Http,
    callbackUrl: '/webhooks/orders/paid',
  },
});
```

**Handle webhook requests**:

```javascript
export async function action({ request }) {
  const { topic, shop, payload } = await authenticate.webhook(request);
  
  switch (topic) {
    case 'PRODUCTS_CREATE':
      await handleProductCreate(shop, payload);
      break;
    case 'ORDERS_PAID':
      await handleOrderPaid(shop, payload);
      break;
  }
  
  return new Response();
}
```

**Webhook security**:
- Validate HMAC signatures
- Use webhook verification helpers from Shopify libraries
- Respond with 200 OK quickly (process async if needed)
- Implement retry logic for failed processing

## App Billing

**Implement usage-based or subscription billing**:

```javascript
// Create a subscription charge
const response = await admin.graphql(
  `#graphql
    mutation appSubscriptionCreate($name: String!, $returnUrl: URL!) {
      appSubscriptionCreate(
        name: $name
        returnUrl: $returnUrl
        lineItems: [{
          plan: {
            appRecurringPricingDetails: {
              price: { amount: 10, currencyCode: USD }
              interval: EVERY_30_DAYS
            }
          }
        }]
      ) {
        userErrors {
          field
          message
        }
        confirmationUrl
        appSubscription {
          id
          status
        }
      }
    }`,
  { variables: { name: "Premium Plan", returnUrl: `${appUrl}/billing/callback` } }
);

// Redirect merchant to confirmationUrl for approval
```

## Testing & Development

**Local development**:
```bash
shopify app dev
# Starts local server with tunnel for OAuth
```

**Testing webhooks locally**:
```bash
shopify app webhooks trigger --topic=products/create
```

**Partner Dashboard testing**:
- Use development stores for testing
- Test installation/uninstallation flows
- Verify GDPR webhook handlers

## Security Best Practices

1. **Validate all requests** - Check HMAC signatures and session tokens
2. **Scope principle** - Request minimum required OAuth scopes
3. **Secure storage** - Encrypt access tokens, use environment variables
4. **HTTPS only** - All app URLs must use HTTPS
5. **GDPR compliance** - Implement mandatory webhooks: `customers/data_request`, `customers/redact`, `shop/redact`
6. **Rate limiting** - Respect API rate limits, implement exponential backoff
7. **Input validation** - Sanitize all user inputs, especially in extensions

## Common Patterns

### Bulk Operations

For processing large datasets:

```javascript
const bulkOperation = await admin.graphql(
  `#graphql
    mutation {
      bulkOperationRunQuery(
        query: """
        {
          products {
            edges {
              node {
                id
                title
              }
            }
          }
        }
        """
      ) {
        bulkOperation {
          id
          status
        }
      }
    }`
);

// Poll for completion or use webhook
```

### Metafields Management

Store custom data on Shopify resources:

```javascript
// Create metafield
await admin.graphql(
  `#graphql
    mutation createMetafield($metafields: [MetafieldsSetInput!]!) {
      metafieldsSet(metafields: $metafields) {
        metafields {
          id
          namespace
          key
          value
        }
      }
    }`,
  {
    variables: {
      metafields: [{
        ownerId: productId,
        namespace: "app",
        key: "custom_data",
        value: JSON.stringify({ setting: true }),
        type: "json"
      }]
    }
  }
);
```

### App Proxy

For public-facing app features:

```javascript
// Configure in Partner Dashboard: /apps/your-app -> App proxy
// Liquid: GET /apps/your-app-slug
// Backend: https://your-app.com/proxy

export async function loader({ request }) {
  const url = new URL(request.url);
  const shop = url.searchParams.get('shop');
  
  // Return HTML/JSON for storefront
  return json({ data: "public data" });
}
```

## Resources & References

This skill includes detailed reference documentation for advanced topics:

- **references/advanced_patterns.md** - Multi-shop management, advanced GraphQL patterns, extension development, webhook processing, billing patterns, performance optimization, and testing strategies
- **references/api_versioning.md** - API version management, migration strategies, breaking changes handling, and upgrade planning

When detailed API information or current examples are needed, use the Shopify Dev MCP server to access:

- **API References**: Latest GraphQL schema, REST API endpoints
- **Tutorial Content**: Step-by-step guides for specific features
- **Code Examples**: Current implementation patterns
- **Migration Guides**: Updates for API version changes

**Primary documentation source**: https://shopify.dev/docs/apps/build

## Version & API Considerations

- Use the **latest stable API version** (currently 2024-01 or newer)
- Monitor deprecation notices for upcoming changes
- Test against multiple API versions if supporting older merchants
- Use webhooks to stay informed of API updates