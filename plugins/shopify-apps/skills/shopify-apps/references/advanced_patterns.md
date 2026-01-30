# Advanced Shopify App Patterns

This reference provides detailed patterns for advanced Shopify app development scenarios.

## Multi-Shop Installation Management

Handle multiple shop installations with proper session management:

```javascript
// Database schema for shop sessions
interface ShopSession {
  shop: string;              // mystore.myshopify.com
  accessToken: string;       // Encrypted access token
  scope: string;             // Granted OAuth scopes
  isOnline: boolean;         // Online vs offline token
  expiresAt?: Date;          // For online tokens
  state: 'active' | 'uninstalled';
}

// Session storage implementation
class SessionStorage {
  async storeSession(session: ShopSession) {
    // Store encrypted token in database
    await db.sessions.upsert({
      where: { shop: session.shop },
      update: session,
      create: session,
    });
  }

  async loadSession(shop: string) {
    const session = await db.sessions.findUnique({
      where: { shop },
    });
    return session;
  }

  async deleteSession(shop: string) {
    await db.sessions.update({
      where: { shop },
      data: { state: 'uninstalled' },
    });
  }
}
```

## Advanced GraphQL Patterns

### Pagination with Cursor-Based Navigation

```javascript
async function fetchAllProducts(admin, cursor = null) {
  const products = [];
  let hasNextPage = true;

  while (hasNextPage) {
    const response = await admin.graphql(
      `#graphql
        query getProducts($cursor: String, $first: Int!) {
          products(first: $first, after: $cursor) {
            edges {
              cursor
              node {
                id
                title
                variants(first: 10) {
                  edges {
                    node {
                      id
                      price
                    }
                  }
                }
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }`,
      {
        variables: {
          cursor,
          first: 50,
        },
      }
    );

    const data = await response.json();
    products.push(...data.data.products.edges.map(edge => edge.node));
    
    hasNextPage = data.data.products.pageInfo.hasNextPage;
    cursor = data.data.products.pageInfo.endCursor;
  }

  return products;
}
```

### Batch Mutations with Error Handling

```javascript
async function batchUpdateProducts(admin, updates) {
  const BATCH_SIZE = 10;
  const results = { success: [], errors: [] };

  for (let i = 0; i < updates.length; i += BATCH_SIZE) {
    const batch = updates.slice(i, i + BATCH_SIZE);
    
    const mutations = batch.map((update, index) => 
      `mutation${index}: productUpdate(input: {
        id: "${update.id}"
        title: "${update.title}"
      }) {
        product { id }
        userErrors { field message }
      }`
    ).join('\n');

    const response = await admin.graphql(`#graphql
      mutation batchUpdate {
        ${mutations}
      }
    `);

    const data = await response.json();
    
    // Process results
    Object.entries(data.data).forEach(([key, result]) => {
      if (result.userErrors.length > 0) {
        results.errors.push({
          mutation: key,
          errors: result.userErrors,
        });
      } else {
        results.success.push(result.product.id);
      }
    });
  }

  return results;
}
```

## App Extension Advanced Patterns

### Checkout UI with External API Integration

```javascript
// extensions/checkout-ui/src/Checkout.jsx
import {
  reactExtension,
  useApi,
  useApplyAttributeChange,
  useExtensionCapability,
  Banner,
} from '@shopify/ui-extensions-react/checkout';
import { useEffect, useState } from 'react';

export default reactExtension(
  'purchase.checkout.block.render',
  () => <ShippingEstimator />
);

function ShippingEstimator() {
  const { cost, shippingAddress } = useApi();
  const [estimate, setEstimate] = useState(null);
  const [loading, setLoading] = useState(false);
  const applyAttributeChange = useApplyAttributeChange();
  const canUpdateAttributes = useExtensionCapability('api_access');

  useEffect(() => {
    async function fetchEstimate() {
      if (!shippingAddress?.address1) return;

      setLoading(true);
      try {
        // Call your app's backend proxy endpoint
        const response = await fetch(
          `/apps/your-app/shipping-estimate?` +
          `address=${encodeURIComponent(shippingAddress.address1)}&` +
          `total=${cost.totalAmount.amount}`
        );
        const data = await response.json();
        setEstimate(data.estimate);
        
        // Store estimate in checkout attributes
        if (canUpdateAttributes) {
          await applyAttributeChange({
            type: 'updateAttribute',
            key: 'shipping_estimate',
            value: data.estimate.toString(),
          });
        }
      } catch (error) {
        console.error('Failed to fetch estimate:', error);
      } finally {
        setLoading(false);
      }
    }

    fetchEstimate();
  }, [shippingAddress, cost.totalAmount.amount]);

  if (loading) return <Banner>Calculating shipping...</Banner>;
  if (!estimate) return null;

  return (
    <Banner status="info">
      Estimated delivery: {estimate} business days
    </Banner>
  );
}
```

### Theme Extension with App Block Communication

```liquid
{% comment %} blocks/product-recommendations.liquid {% endcomment %}
<div class="product-recommendations" data-product-id="{{ product.id }}">
  <h3>{{ block.settings.heading }}</h3>
  <div class="recommendations-container" id="recommendations-{{ block.id }}">
    <p>Loading recommendations...</p>
  </div>
</div>

<script>
  (async function() {
    const container = document.getElementById('recommendations-{{ block.id }}');
    const productId = container.closest('[data-product-id]').dataset.productId;
    
    try {
      const response = await fetch(
        `/apps/{{ app_handle }}/recommendations?product_id=${productId}`,
        {
          headers: {
            'Content-Type': 'application/json',
          }
        }
      );
      
      const { products } = await response.json();
      
      container.innerHTML = products.map(p => `
        <div class="recommendation-item">
          <img src="${p.image}" alt="${p.title}">
          <h4>${p.title}</h4>
          <p>${p.price}</p>
        </div>
      `).join('');
    } catch (error) {
      container.innerHTML = '<p>Unable to load recommendations</p>';
    }
  })();
</script>

{% schema %}
{
  "name": "Product Recommendations",
  "target": "section",
  "settings": [
    {
      "type": "text",
      "id": "heading",
      "label": "Heading",
      "default": "Recommended for you"
    },
    {
      "type": "range",
      "id": "products_to_show",
      "min": 2,
      "max": 8,
      "step": 1,
      "label": "Products to show",
      "default": 4
    }
  ]
}
{% endschema %}
```

## Webhook Advanced Patterns

### Webhook Queue Processing

```javascript
// Robust webhook processing with queue
import { Queue } from 'bullmq';

const webhookQueue = new Queue('shopify-webhooks', {
  connection: redisConnection,
});

// Webhook endpoint
export async function action({ request }) {
  const { topic, shop, payload } = await authenticate.webhook(request);
  
  // Add to queue for async processing
  await webhookQueue.add(
    topic,
    {
      shop,
      topic,
      payload,
      receivedAt: new Date().toISOString(),
    },
    {
      attempts: 3,
      backoff: {
        type: 'exponential',
        delay: 2000,
      },
    }
  );
  
  // Respond immediately
  return new Response(null, { status: 200 });
}

// Worker process
import { Worker } from 'bullmq';

const worker = new Worker(
  'shopify-webhooks',
  async (job) => {
    const { shop, topic, payload } = job.data;
    
    switch (topic) {
      case 'PRODUCTS_CREATE':
        await processProductCreate(shop, payload);
        break;
      case 'ORDERS_PAID':
        await processOrderPaid(shop, payload);
        break;
      // ... other handlers
    }
  },
  { connection: redisConnection }
);

worker.on('failed', (job, err) => {
  console.error(`Webhook job ${job.id} failed:`, err);
  // Send alert, log to monitoring service, etc.
});
```

### GDPR Webhook Compliance

```javascript
// Required GDPR webhook handlers
const gdprHandlers = {
  // Customer data request (48 hour response required)
  CUSTOMERS_DATA_REQUEST: async (shop, payload) => {
    const { customer, orders_requested } = payload;
    
    // Gather all customer data from your database
    const customerData = await db.customers.findUnique({
      where: { 
        shopifyCustomerId: customer.id,
        shop,
      },
      include: {
        orders: true,
        preferences: true,
        activityLog: true,
      },
    });
    
    // Format and send data to customer email
    await sendCustomerDataEmail(customer.email, customerData);
    
    // Log compliance action
    await db.gdprLogs.create({
      data: {
        type: 'DATA_REQUEST',
        shop,
        customerId: customer.id,
        processedAt: new Date(),
      },
    });
  },

  // Customer data erasure
  CUSTOMERS_REDACT: async (shop, payload) => {
    const { customer, orders_to_redact } = payload;
    
    // Delete or anonymize customer data
    await db.customers.update({
      where: {
        shopifyCustomerId: customer.id,
        shop,
      },
      data: {
        email: `deleted-${customer.id}@privacy.local`,
        name: 'REDACTED',
        // Keep order history for accounting but anonymize
        orders: {
          updateMany: {
            where: { customerId: customer.id },
            data: {
              customerName: 'REDACTED',
              shippingAddress: null,
            },
          },
        },
      },
    });
    
    await db.gdprLogs.create({
      data: {
        type: 'CUSTOMER_REDACT',
        shop,
        customerId: customer.id,
        processedAt: new Date(),
      },
    });
  },

  // Shop data erasure (when app is uninstalled)
  SHOP_REDACT: async (shop, payload) => {
    // Delete all shop data after 48 hours of uninstall
    await db.$transaction([
      db.sessions.deleteMany({ where: { shop } }),
      db.customers.deleteMany({ where: { shop } }),
      db.appData.deleteMany({ where: { shop } }),
    ]);
    
    await db.gdprLogs.create({
      data: {
        type: 'SHOP_REDACT',
        shop,
        processedAt: new Date(),
      },
    });
  },
};
```

## App Billing Advanced Patterns

### Usage-Based Billing

```javascript
async function trackUsage(shop, metric, value) {
  // Get active subscription
  const subscription = await getActiveSubscription(shop);
  
  if (!subscription.usageChargeId) return;
  
  // Create usage record
  const response = await admin.graphql(
    `#graphql
      mutation appUsageRecordCreate($subscriptionLineItemId: ID!, $price: MoneyInput!, $description: String!) {
        appUsageRecordCreate(
          subscriptionLineItemId: $subscriptionLineItemId
          price: $price
          description: $description
        ) {
          userErrors {
            field
            message
          }
          appUsageRecord {
            id
            price { amount }
          }
        }
      }`,
    {
      variables: {
        subscriptionLineItemId: subscription.usageChargeId,
        price: {
          amount: value,
          currencyCode: 'USD',
        },
        description: `${metric}: ${value} units`,
      },
    }
  );
  
  const data = await response.json();
  
  // Store usage record for reporting
  await db.usageRecords.create({
    data: {
      shop,
      metric,
      value,
      recordId: data.data.appUsageRecordCreate.appUsageRecord.id,
      createdAt: new Date(),
    },
  });
}

// Usage tracking middleware
async function trackApiCall(shop, endpoint) {
  await trackUsage(shop, 'api_calls', 0.01); // $0.01 per call
}
```

### Trial Period Management

```javascript
async function checkTrialStatus(shop) {
  const installation = await db.installations.findUnique({
    where: { shop },
  });
  
  const trialEnd = new Date(installation.installedAt);
  trialEnd.setDate(trialEnd.getDate() + 14); // 14-day trial
  
  const isInTrial = new Date() < trialEnd;
  const daysRemaining = Math.ceil((trialEnd - new Date()) / (1000 * 60 * 60 * 24));
  
  return {
    isInTrial,
    daysRemaining,
    trialEnd,
  };
}

// Billing enforcement
export async function requiresSubscription(request) {
  const { session } = await authenticate.admin(request);
  
  const trial = await checkTrialStatus(session.shop);
  
  if (trial.isInTrial) {
    return { allowed: true, trial };
  }
  
  const subscription = await getActiveSubscription(session.shop);
  
  if (!subscription || subscription.status !== 'ACTIVE') {
    throw redirect('/billing');
  }
  
  return { allowed: true, subscription };
}
```

## Performance Optimization

### GraphQL Query Batching

```javascript
// Batch multiple queries into single request
async function batchQueries(admin, queries) {
  const batchedQuery = queries
    .map((q, i) => `query${i}: ${q.query}`)
    .join('\n');
  
  const response = await admin.graphql(`#graphql
    {
      ${batchedQuery}
    }
  `);
  
  const data = await response.json();
  
  return queries.map((_, i) => data.data[`query${i}`]);
}

// Usage
const [products, customers] = await batchQueries(admin, [
  { query: 'products(first: 10) { edges { node { id title } } }' },
  { query: 'customers(first: 10) { edges { node { id email } } }' },
]);
```

### Caching Strategies

```javascript
import { LRUCache } from 'lru-cache';

// In-memory cache for frequently accessed data
const cache = new LRUCache({
  max: 500,
  ttl: 1000 * 60 * 5, // 5 minutes
});

async function getCachedProduct(admin, productId) {
  const cacheKey = `product:${productId}`;
  
  // Check cache first
  let product = cache.get(cacheKey);
  
  if (!product) {
    // Fetch from API
    const response = await admin.graphql(
      `#graphql
        query getProduct($id: ID!) {
          product(id: $id) {
            id
            title
            variants(first: 100) {
              edges {
                node { id price }
              }
            }
          }
        }`,
      { variables: { id: productId } }
    );
    
    const data = await response.json();
    product = data.data.product;
    
    // Store in cache
    cache.set(cacheKey, product);
  }
  
  return product;
}

// Invalidate cache on webhook
async function handleProductUpdate(shop, payload) {
  cache.delete(`product:${payload.id}`);
  // ... process update
}
```

## Testing Strategies

### Integration Testing with Test Shops

```javascript
import { describe, it, expect, beforeAll } from 'vitest';

describe('Shopify App Integration', () => {
  let testShop;
  let admin;

  beforeAll(async () => {
    // Use development store credentials
    testShop = process.env.TEST_SHOP_DOMAIN;
    admin = await createAdminClient(testShop);
  });

  it('should create a product', async () => {
    const response = await admin.graphql(
      `#graphql
        mutation createProduct($input: ProductInput!) {
          productCreate(input: $input) {
            product {
              id
              title
            }
            userErrors {
              field
              message
            }
          }
        }`,
      {
        variables: {
          input: {
            title: 'Test Product',
            vendor: 'Test Vendor',
          },
        },
      }
    );

    const data = await response.json();
    expect(data.data.productCreate.userErrors).toHaveLength(0);
    expect(data.data.productCreate.product.title).toBe('Test Product');
    
    // Cleanup
    await deleteProduct(admin, data.data.productCreate.product.id);
  });

  it('should handle webhook', async () => {
    const webhookPayload = {
      id: 123456,
      title: 'Test Product',
    };

    const response = await fetch('http://localhost:3000/webhooks/products/create', {
      method: 'POST',
      headers: {
        'X-Shopify-Topic': 'products/create',
        'X-Shopify-Shop-Domain': testShop,
        'X-Shopify-Hmac-Sha256': generateHmac(webhookPayload),
      },
      body: JSON.stringify(webhookPayload),
    });

    expect(response.status).toBe(200);
  });
});
```