const MAX_ROWS = 200;
const MAX_CELLS = 2000;
const MAX_TAG_LENGTH = 512;
const STRUCTURAL_TAG = /^\s*(\/)?(table|tr|td)(?:=(.*))?\s*$/is;

function escapedAt(source, index) {
  let backslashes = 0;

  for (
    let cursor = index - 1;
    cursor >= 0 && source[cursor] === "\\";
    cursor--
  ) {
    backslashes++;
  }

  return backslashes % 2 === 1;
}

function structuralTagAt(source, start) {
  const closingBracket = source.indexOf("]", start + 1);

  if (
    closingBracket === -1 ||
    closingBracket - start > MAX_TAG_LENGTH ||
    escapedAt(source, start)
  ) {
    return null;
  }

  const match = source.slice(start + 1, closingBracket).match(STRUCTURAL_TAG);

  if (!match || (match[1] && match[3] !== undefined)) {
    return null;
  }

  return {
    name: match[2].toLowerCase(),
    closing: Boolean(match[1]),
    attributes: match[3],
    end: closingBracket + 1,
  };
}

function parseCellAttributes(attributes) {
  if (attributes === undefined || attributes.trim() === "") {
    return { colspan: 1, rowspan: 1 };
  }

  const parts = attributes.split(",").map((part) => part.trim());

  if (parts.length === 1) {
    return /^\d{1,4}%?$/.test(parts[0]) ? { colspan: 1, rowspan: 1 } : null;
  }

  if (
    parts.length < 2 ||
    parts.length > 3 ||
    !/^\d{1,2}$/.test(parts[0]) ||
    !/^\d{1,2}$/.test(parts[1]) ||
    (parts.length === 3 && !/^\d{1,4}%?$/.test(parts[2]))
  ) {
    return null;
  }

  const colspan = Number.parseInt(parts[0], 10);
  const rowspan = Number.parseInt(parts[1], 10);

  if (colspan < 1 || rowspan < 1 || colspan > 99 || rowspan > 99) {
    return null;
  }

  return { colspan, rowspan };
}

function parseExplicitTable(source) {
  const rows = [];
  let row = null;
  let cell = null;
  let cursor = 0;
  let cellCount = 0;
  let found = false;

  function appendText(text) {
    if (cell) {
      cell.content += text;
    } else if (text.trim() !== "") {
      return false;
    }

    return true;
  }

  function closeCell() {
    if (cell && row) {
      row.cells.push(cell);
      cell = null;
      cellCount++;
    }

    return cellCount <= MAX_CELLS;
  }

  function closeRow() {
    if (!row || !closeCell()) {
      return false;
    }

    rows.push(row);
    row = null;
    return rows.length <= MAX_ROWS;
  }

  for (let index = 0; index < source.length; index++) {
    if (source[index] !== "[") {
      continue;
    }

    const tag = structuralTagAt(source, index);

    if (!tag) {
      continue;
    }

    if (tag.name === "table") {
      return { found: true, rows: null };
    }

    found = true;

    if (!appendText(source.slice(cursor, index))) {
      return { found, rows: null };
    }

    if (tag.name === "tr") {
      if (tag.closing) {
        if (!row || !closeRow()) {
          return { found, rows: null };
        }
      } else {
        if (row && !closeRow()) {
          return { found, rows: null };
        }

        row = { cells: [] };
      }
    } else if (tag.name === "td") {
      if (tag.closing) {
        if (!row || !cell || !closeCell()) {
          return { found, rows: null };
        }
      } else {
        if (!row || !closeCell()) {
          return { found, rows: null };
        }

        const attributes = parseCellAttributes(tag.attributes);

        if (!attributes) {
          return { found, rows: null };
        }

        cell = { ...attributes, content: "" };
      }
    }

    cursor = tag.end;
    index = tag.end - 1;
  }

  if (!appendText(source.slice(cursor))) {
    return { found, rows: null };
  }

  if (row && !closeRow()) {
    return { found, rows: null };
  }

  if (!found) {
    return { found: false, rows: null };
  }

  if (
    rows.length === 0 ||
    !rows.some((tableRow) => tableRow.cells.length > 0)
  ) {
    return { found: true, rows: null };
  }

  return { found: true, rows };
}

function splitLegacyRow(line) {
  const cells = [];
  let cell = "";

  for (let index = 0; index < line.length; index++) {
    if (line[index] === "\\" && line[index + 1] === "|") {
      cell += "|";
      index++;
    } else if (line[index] === "\\" && line[index + 1] === "n") {
      cell += "\n";
      index++;
    } else if (line[index] === "|") {
      cells.push({ colspan: 1, rowspan: 1, content: cell });
      cell = "";
    } else {
      cell += line[index];
    }
  }

  cells.push({ colspan: 1, rowspan: 1, content: cell });
  return cells;
}

function parseLegacyTable(source) {
  const contents = source.trim();

  if (contents === "") {
    return null;
  }

  const lines = contents.split(/\r\n?|\n/);

  if (lines.length > MAX_ROWS) {
    return null;
  }

  const rows = lines.map((line) => ({ cells: splitLegacyRow(line) }));
  const cellCount = rows.reduce((total, row) => total + row.cells.length, 0);

  return cellCount <= MAX_CELLS ? rows : null;
}

function renderRows(rows, md, env) {
  const renderedRows = rows.map((row) => {
    const cells = row.cells
      .map((cell) => {
        const attributes = [];

        if (cell.colspan > 1) {
          attributes.push('colspan="' + cell.colspan + '"');
        }

        if (cell.rowspan > 1) {
          attributes.push('rowspan="' + cell.rowspan + '"');
        }

        const attrs = attributes.length > 0 ? " " + attributes.join(" ") : "";
        return (
          "<td" + attrs + ">" + md.renderInline(cell.content, env) + "</td>"
        );
      })
      .join("");

    return "<tr>" + cells + "</tr>";
  });

  return (
    '<div class="md-table"><table><tbody>' +
    renderedRows.join("") +
    "</tbody></table></div>"
  );
}

export function setup(helper) {
  if (!helper.markdownIt) {
    return;
  }

  helper.allowList([
    "div.md-table",
    "table",
    "tbody",
    "tr",
    "td",
    "td[colspan]",
    "td[rowspan]",
    "span[data-discuz-attachment][data-aid]",
    "span[data-discuz-sell-section][data-pid][data-cid]",
  ]);

  helper.registerOptions((opts, siteSettings) => {
    opts.features.discuz_bbcode_tables =
      siteSettings.discourse_discuz_bbcode_tables_enabled;
    opts.features.discuz_bbcode_attachments =
      siteSettings.discourse_discuz_bbcode_attachments_enabled;
    opts.features.discuz_bbcode_sell =
      siteSettings.discourse_discuz_bbcode_sell_enabled;
  });

  helper.registerPlugin((md) => {
    if (md.options.discourse.features.discuz_bbcode_tables) {
      md.block.bbcode.ruler.push("discuz-table", {
        tag: "table",

        replace(state, _tagInfo, content) {
          const explicit = parseExplicitTable(content);
          const rows = explicit.found
            ? explicit.rows
            : parseLegacyTable(content);

          if (!rows) {
            return false;
          }

          const token = state.push("discuz_bbcode_table", "", 0);
          token.block = true;
          token.content = renderRows(rows, md, state.env);
          return true;
        },
      });

      md.renderer.rules.discuz_bbcode_table = (tokens, index) =>
        tokens[index].content;
    }

    if (md.options.discourse.features.discuz_bbcode_attachments) {
      md.inline.bbcode.ruler.push("discuz-attachment", {
        tag: "attach",

        replace(state, _tagInfo, content) {
          const aid = content.trim();
          if (!/^[1-9]\d*$/.test(aid)) {
            return false;
          }

          const token = state.push("discuz_bbcode_attachment", "", 0);
          token.content = aid;
          return true;
        },
      });

      md.renderer.rules.discuz_bbcode_attachment = (tokens, index) => {
        const aid = tokens[index].content;
        return `<span data-discuz-attachment="true" data-aid="${aid}">[Discuz 附件 ${aid}]</span>`;
      };
    }

    if (md.options.discourse.features.discuz_bbcode_sell) {
      md.inline.bbcode.ruler.push("discuz-sell-section", {
        tag: "discuzsell",

        replace(state, _tagInfo, content) {
          const match = content.trim().match(/^(\d+):(\d+)$/);
          if (!match) {
            return false;
          }

          const token = state.push("discuz_bbcode_sell_section", "", 0);
          token.meta = { pid: match[1], cid: match[2] };
          return true;
        },
      });

      md.renderer.rules.discuz_bbcode_sell_section = (tokens, index) => {
        const { pid, cid } = tokens[index].meta;
        return `<span data-discuz-sell-section="true" data-pid="${pid}" data-cid="${cid}">付费内容</span>`;
      };
    }
  });
}
