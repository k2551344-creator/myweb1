// Intentionally empty by default.
// Add Drizzle tables here when the site actually needs a database.
// See examples/d1/db/schema.ts for an opt-in example.
import { sqliteTable, text, integer } from 'drizzle-orm/sqlite-core';
// Private demonstration storage. Production uses the normalized Supabase schema.
export const demoState=sqliteTable('demo_state',{owner:text('owner').primaryKey(),revision:integer('revision').notNull().default(0),data:text('data').notNull()});
