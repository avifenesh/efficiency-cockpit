//! Search module for the Efficiency Cockpit.
//!
//! Provides full-text search capabilities using Tantivy.

use anyhow::{Context, Result};
use std::path::Path;
use tantivy::collector::TopDocs;
use tantivy::query::QueryParser;
use tantivy::schema::{Field, Schema, Value, STORED, TEXT};
use tantivy::{doc, Index, IndexWriter, ReloadPolicy, TantivyDocument};

/// Search index for file content and metadata.
pub struct SearchIndex {
    index: Index,
    schema: SearchSchema,
}

/// Schema fields for the search index.
#[derive(Clone)]
struct SearchSchema {
    schema: Schema,
    path: Field,
    content: Field,
    title: Field,
}

/// A document that can be indexed.
#[derive(Debug, Clone)]
pub struct IndexDocument {
    pub path: String,
    pub title: String,
    pub content: String,
}

/// A search result.
#[derive(Debug, Clone)]
pub struct SearchResult {
    pub path: String,
    pub title: String,
    pub score: f32,
}

impl SearchIndex {
    /// Create a new search index at the given path.
    pub fn create(index_path: impl AsRef<Path>) -> Result<Self> {
        let index_path = index_path.as_ref();
        std::fs::create_dir_all(index_path)
            .with_context(|| format!("Failed to create index directory: {}", index_path.display()))?;

        let schema = Self::build_schema();
        let index = Index::create_in_dir(index_path, schema.schema.clone())
            .with_context(|| format!("Failed to create search index: {}", index_path.display()))?;

        Ok(Self { index, schema })
    }

    /// Open an existing search index.
    pub fn open(index_path: impl AsRef<Path>) -> Result<Self> {
        let index_path = index_path.as_ref();
        let schema = Self::build_schema();
        let index = Index::open_in_dir(index_path)
            .with_context(|| format!("Failed to open search index: {}", index_path.display()))?;

        Ok(Self { index, schema })
    }

    /// Create or open an index (creates if doesn't exist).
    pub fn create_or_open(index_path: impl AsRef<Path>) -> Result<Self> {
        let index_path = index_path.as_ref();
        if index_path.join("meta.json").exists() {
            Self::open(index_path)
        } else {
            Self::create(index_path)
        }
    }

    /// Create an in-memory index for testing.
    pub fn create_in_memory() -> Result<Self> {
        let schema = Self::build_schema();
        let index = Index::create_in_ram(schema.schema.clone());

        Ok(Self { index, schema })
    }

    /// Build the search schema.
    fn build_schema() -> SearchSchema {
        let mut schema_builder = Schema::builder();

        let path = schema_builder.add_text_field("path", TEXT | STORED);
        let content = schema_builder.add_text_field("content", TEXT);
        let title = schema_builder.add_text_field("title", TEXT | STORED);

        let schema = schema_builder.build();

        SearchSchema {
            schema,
            path,
            content,
            title,
        }
    }

    /// Get an index writer for adding documents.
    pub fn writer(&self) -> Result<SearchIndexWriter> {
        let writer = self
            .index
            .writer(50_000_000) // 50MB heap
            .context("Failed to create index writer")?;

        Ok(SearchIndexWriter {
            writer,
            schema: self.schema.clone(),
        })
    }

    /// Search the index.
    pub fn search(&self, query_str: &str, limit: usize) -> Result<Vec<SearchResult>> {
        let reader = self
            .index
            .reader_builder()
            .reload_policy(ReloadPolicy::OnCommitWithDelay)
            .try_into()
            .context("Failed to create index reader")?;

        let searcher = reader.searcher();
        let query_parser = QueryParser::for_index(&self.index, vec![self.schema.content, self.schema.title]);

        let query = query_parser
            .parse_query(query_str)
            .with_context(|| format!("Failed to parse query: {}", query_str))?;

        let top_docs = searcher
            .search(&query, &TopDocs::with_limit(limit))
            .context("Search failed")?;

        let mut results = Vec::with_capacity(top_docs.len());
        for (score, doc_address) in top_docs {
            let doc: TantivyDocument = searcher
                .doc(doc_address)
                .context("Failed to retrieve document")?;

            let path = doc
                .get_first(self.schema.path)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            let title = doc
                .get_first(self.schema.title)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            results.push(SearchResult { path, title, score });
        }

        Ok(results)
    }
}

/// Writer for adding documents to the index.
pub struct SearchIndexWriter {
    writer: IndexWriter,
    schema: SearchSchema,
}

impl SearchIndexWriter {
    /// Add a document to the index.
    pub fn add_document(&mut self, doc: &IndexDocument) -> Result<()> {
        self.writer.add_document(doc!(
            self.schema.path => doc.path.clone(),
            self.schema.title => doc.title.clone(),
            self.schema.content => doc.content.clone(),
        ))?;

        Ok(())
    }

    /// Add multiple documents to the index.
    pub fn add_documents(&mut self, docs: &[IndexDocument]) -> Result<()> {
        for doc in docs {
            self.add_document(doc)?;
        }
        Ok(())
    }

    /// Commit changes to the index.
    pub fn commit(mut self) -> Result<()> {
        self.writer.commit().context("Failed to commit index")?;
        Ok(())
    }

    /// Delete all documents matching a path.
    pub fn delete_by_path(&mut self, path: &str) {
        let term = tantivy::Term::from_field_text(self.schema.path, path);
        self.writer.delete_term(term);
    }
}

/// Read file content for indexing.
pub fn read_file_for_indexing(path: &Path) -> Option<IndexDocument> {
    // Only index text files
    let extension = path.extension()?.to_str()?;
    let text_extensions = ["rs", "txt", "md", "json", "toml", "yaml", "yml", "py", "js", "ts", "html", "css"];

    if !text_extensions.contains(&extension) {
        return None;
    }

    let content = std::fs::read_to_string(path).ok()?;
    let title = path.file_name()?.to_string_lossy().to_string();

    Some(IndexDocument {
        path: path.to_string_lossy().to_string(),
        title,
        content,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_in_memory_index() {
        let index = SearchIndex::create_in_memory().unwrap();
        let results = index.search("test", 10).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_index_and_search() {
        let index = SearchIndex::create_in_memory().unwrap();
        let mut writer = index.writer().unwrap();

        writer
            .add_document(&IndexDocument {
                path: "/src/main.rs".to_string(),
                title: "main.rs".to_string(),
                content: "fn main() { println!(\"Hello, world!\"); }".to_string(),
            })
            .unwrap();

        writer
            .add_document(&IndexDocument {
                path: "/src/lib.rs".to_string(),
                title: "lib.rs".to_string(),
                content: "pub mod database; pub mod config;".to_string(),
            })
            .unwrap();

        writer.commit().unwrap();

        let results = index.search("main", 10).unwrap();
        assert!(!results.is_empty());
        assert!(results.iter().any(|r| r.path == "/src/main.rs"));
    }

    #[test]
    fn test_search_by_content() {
        let index = SearchIndex::create_in_memory().unwrap();
        let mut writer = index.writer().unwrap();

        writer
            .add_document(&IndexDocument {
                path: "/docs/readme.md".to_string(),
                title: "readme.md".to_string(),
                content: "This is a productivity tool for developers".to_string(),
            })
            .unwrap();

        writer.commit().unwrap();

        let results = index.search("productivity", 10).unwrap();
        assert!(!results.is_empty());
        assert_eq!(results[0].path, "/docs/readme.md");
    }

    #[test]
    fn test_read_file_for_indexing_rs() {
        use tempfile::tempdir;

        let dir = tempdir().unwrap();
        let file_path = dir.path().join("test.rs");
        std::fs::write(&file_path, "fn test() {}").unwrap();

        let doc = read_file_for_indexing(&file_path).unwrap();
        assert_eq!(doc.title, "test.rs");
        assert!(doc.content.contains("fn test"));
    }

    #[test]
    fn test_read_file_for_indexing_non_text() {
        use tempfile::tempdir;

        let dir = tempdir().unwrap();
        let file_path = dir.path().join("image.png");
        std::fs::write(&file_path, &[0u8; 100]).unwrap();

        let doc = read_file_for_indexing(&file_path);
        assert!(doc.is_none());
    }

    #[test]
    fn test_add_multiple_documents() {
        let index = SearchIndex::create_in_memory().unwrap();
        let mut writer = index.writer().unwrap();

        let docs = vec![
            IndexDocument {
                path: "/a.rs".to_string(),
                title: "a.rs".to_string(),
                content: "function alpha".to_string(),
            },
            IndexDocument {
                path: "/b.rs".to_string(),
                title: "b.rs".to_string(),
                content: "function beta".to_string(),
            },
        ];

        writer.add_documents(&docs).unwrap();
        writer.commit().unwrap();

        let results = index.search("function", 10).unwrap();
        assert_eq!(results.len(), 2);
    }
}
