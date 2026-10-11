import { Client } from "@notionhq/client";

export const notion = new Client({ auth: process.env.NOTION_TOKEN });

export const DB = {
  log: process.env.NOTION_LOG_DS!,
  goals: process.env.NOTION_GOALS_DS!,
  tasks: process.env.NOTION_TASKS_DS!,
};

// Fetch all pages from a data source (handles pagination)
export async function queryAll(dataSourceId: string, filter?: object, sorts?: object[]) {
  const results = [];
  let cursor: string | undefined;

  do {
    const resp = await notion.dataSources.query({
      data_source_id: dataSourceId,
      filter: filter as any,
      sorts: sorts as any,
      start_cursor: cursor,
      page_size: 100,
    });
    results.push(...resp.results);
    cursor = resp.has_more ? resp.next_cursor ?? undefined : undefined;
  } while (cursor);

  return results;
}

export function getProp(page: any, name: string) {
  return page.properties?.[name];
}

export function getNumber(page: any, name: string): number | null {
  const p = getProp(page, name);
  return p?.type === "number" ? p.number : null;
}

export function getText(page: any, name: string): string {
  const p = getProp(page, name);
  if (p?.type === "title") return p.title?.[0]?.plain_text ?? "";
  if (p?.type === "rich_text") return p.rich_text?.[0]?.plain_text ?? "";
  return "";
}

export function getDate(page: any, name: string): string | null {
  const p = getProp(page, name);
  return p?.type === "date" ? p.date?.start ?? null : null;
}

export function getSelect(page: any, name: string): string | null {
  const p = getProp(page, name);
  return p?.type === "select" ? p.select?.name ?? null : null;
}

export function getMultiSelect(page: any, name: string): string[] {
  const p = getProp(page, name);
  return p?.type === "multi_select" ? p.multi_select?.map((o: any) => o.name) : [];
}

export function getStatus(page: any, name: string): string | null {
  const p = getProp(page, name);
  return p?.type === "status" ? p.status?.name ?? null : null;
}

export function getFormula(page: any, name: string): string | number | null {
  const p = getProp(page, name);
  if (p?.type !== "formula") return null;
  const f = p.formula;
  if (f?.type === "number") return f.number;
  if (f?.type === "string") return f.string;
  return null;
}

export function getCreatedTime(page: any): string {
  return page.created_time ?? "";
}
