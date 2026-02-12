package database

import (
	"database/sql"
	"encoding/json"
	"time"
)

type PPTXFile struct {
	ID               int             `json:"id"`
	Filename         string          `json:"filename"`
	OriginalFilePath string          `json:"original_file_path"`
	TemplateFilePath string          `json:"template_file_path"`
	ThumbnailDirPath *string         `json:"thumbnail_dir_path"`
	Metadata         json.RawMessage `json:"metadata"`
	IsTemplate       bool            `json:"is_template"`
	AISummary        string          `json:"ai_summary"`
	Title            string          `json:"title"`
	Checksum         string          `json:"checksum"`
	Status           string          `json:"status"`
	UnpackedPath     *string         `json:"unpacked_path"`
	PreviewThumbnail string          `json:"preview_thumbnail"`
	TenantID         string          `json:"tenant_id"`
	ThemeID          *string         `json:"theme_id"`
	CreatedAt        time.Time       `json:"created_at"`
}

type Slide struct {
	ID          int             `json:"id"`
	PPTXFileID  int             `json:"pptx_file_id"`
	SlideNumber int             `json:"slide_number"`
	PNGPath     string          `json:"png_path"`
	Content     string          `json:"content"`
	StyleInfo   json.RawMessage `json:"style_info"`
	AIAnalysis  json.RawMessage `json:"ai_analysis"`
	AISummary   string          `json:"ai_summary"`
	Title       string          `json:"title"`
	Comments    string          `json:"comments"`
	TenantID    string          `json:"tenant_id"`
	HTMXContent string          `json:"htmx_content"`
	CreatedAt   time.Time       `json:"created_at"`
}

type PPTXWithSlides struct {
	PPTXFile
	Slides []Slide `json:"slides"`
}

type AIUsage struct {
	ID               int       `json:"id"`
	Provider         string    `json:"provider"`
	Model            string    `json:"model"`
	PromptTokens     int       `json:"prompt_tokens"`
	CompletionTokens int       `json:"completion_tokens"`
	TotalTokens      int       `json:"total_tokens"`
	Cost             float64   `json:"cost"`
	CreatedAt        time.Time `json:"created_at"`
}

type Tenant struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

type Theme struct {
	ID          string    `json:"id"`
	TenantID    string    `json:"tenant_id"`
	Name        string    `json:"name"`
	Description string    `json:"description"`
	CreatedAt   time.Time `json:"created_at"`
}

type SlideKnowledge struct {
	ID          string          `json:"id"`
	TenantID    string          `json:"tenant_id"`
	ThemeID     string          `json:"theme_id"`
	PPTXFileID  int             `json:"pptx_file_id"`
	SlideNumber int             `json:"slide_number"`
	Content     string          `json:"content"`
	AISummary   string          `json:"ai_summary"`
	Metadata    json.RawMessage `json:"metadata"`
	CreatedAt   time.Time       `json:"created_at"`
}

type SummarizedSlide struct {
	ID                string          `json:"id"`
	TenantID          string          `json:"tenant_id"`
	ThemeID           string          `json:"theme_id"`
	Title             string          `json:"title"`
	SeedContent       string          `json:"seed_content"`
	Placeholders      json.RawMessage `json:"placeholders"` // List of {name, description, distinct_values}
	ReferenceSlideIDs []int           `json:"reference_slide_ids"`
	CreatedAt         time.Time       `json:"created_at"`
}

func SavePPTXMetadata(db *sql.DB, f *PPTXFile) (int, error) {
	data, err := json.Marshal(f)
	if err != nil {
		return 0, err
	}

	var result []byte
	err = db.QueryRow("SELECT deckforge.upsert_pptx_file($1)", data).Scan(&result)
	if err != nil {
		return 0, err
	}

	var updatedFile PPTXFile
	if err := json.Unmarshal(result, &updatedFile); err != nil {
		return 0, err
	}
	return updatedFile.ID, nil
}

func SaveSummarizedSlide(db *sql.DB, s *SummarizedSlide) error {
	query := `
		INSERT INTO deckforge.summarized_slides (tenant_id, theme_id, title, seed_content, placeholders, reference_slide_ids)
		VALUES ($1, $2, $3, $4, $5, $6)
	`
	_, err := db.Exec(query, s.TenantID, s.ThemeID, s.Title, s.SeedContent, s.Placeholders, s.ReferenceSlideIDs)
	return err
}

func GetSummarizedSlidesByTheme(db *sql.DB, tenantID, themeID string) ([]SummarizedSlide, error) {
	query := `
		SELECT id, tenant_id, theme_id, title, seed_content, placeholders, reference_slide_ids, created_at
		FROM deckforge.summarized_slides
		WHERE tenant_id = $1 AND theme_id = $2
		ORDER BY created_at ASC
	`
	rows, err := db.Query(query, tenantID, themeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []SummarizedSlide
	for rows.Next() {
		var s SummarizedSlide
		var refIDs []byte // Handle array
		err := rows.Scan(&s.ID, &s.TenantID, &s.ThemeID, &s.Title, &s.SeedContent, &s.Placeholders, &refIDs, &s.CreatedAt)
		if err != nil {
			return nil, err
		}
		// PostgreSQL array handling in Go can be tricky, for now assuming it's returned in a way scan can handle or simplified.
		// Usually for integer[] we might need pq.Array but since we are not using pq directly here (sql.DB),
		// we might need to be careful.
		// If using jackc/pgx it's easier.
		results = append(results, s)
	}
	return results, nil
}

func GetPPTXByChecksum(db *sql.DB, checksum string) (*PPTXFile, error) {
	var result []byte
	err := db.QueryRow("SELECT deckforge.get_pptx_file(NULL, $1)", checksum).Scan(&result)
	if err != nil {
		return nil, err
	}

	var f PPTXFile
	if err := json.Unmarshal(result, &f); err != nil {
		return nil, err
	}
	return &f, nil
}

func GetPPTXByOriginalPath(db *sql.DB, path string) (*PPTXFile, error) {
	// We don't have a direct stored procedure for original_file_path yet,
	// but we can add one or use explicit schema here.
	// Actually, let's keep it simple and use explicit schema.
	var f PPTXFile
	query := "SELECT id, filename, original_file_path, thumbnail_dir_path, is_template, metadata, ai_summary, title, checksum, status, unpacked_path, preview_thumbnail, created_at FROM deckforge.pptx_files WHERE original_file_path = $1"
	err := db.QueryRow(query, path).Scan(&f.ID, &f.Filename, &f.OriginalFilePath, &f.ThumbnailDirPath, &f.IsTemplate, &f.Metadata, &f.AISummary, &f.Title, &f.Checksum, &f.Status, &f.UnpackedPath, &f.PreviewThumbnail, &f.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &f, nil
}

func GetPPTXByID(db *sql.DB, id int) (*PPTXFile, error) {
	var result []byte
	err := db.QueryRow("SELECT deckforge.get_pptx_file($1, NULL)", id).Scan(&result)
	if err != nil {
		return nil, err
	}

	var f PPTXFile
	if err := json.Unmarshal(result, &f); err != nil {
		return nil, err
	}
	return &f, nil
}

func UpdatePPTXTitle(db *sql.DB, id int, title string) error {
	f := map[string]interface{}{"id": id, "title": title}
	data, err := json.Marshal(f)
	if err != nil {
		return err
	}
	_, err = db.Exec("SELECT deckforge.upsert_pptx_file($1)", data)
	return err
}

func UpdatePPTXSummary(db *sql.DB, id int, summary string) error {
	f := map[string]interface{}{"id": id, "ai_summary": summary}
	data, err := json.Marshal(f)
	if err != nil {
		return err
	}
	_, err = db.Exec("SELECT deckforge.upsert_pptx_file($1)", data)
	return err
}

func UpdatePPTXStatus(db *sql.DB, id int, status string) error {
	f := map[string]interface{}{"id": id, "status": status}
	data, err := json.Marshal(f)
	if err != nil {
		return err
	}
	_, err = db.Exec("SELECT deckforge.upsert_pptx_file($1)", data)
	return err
}

func UpdatePPTXUnpackedPath(db *sql.DB, id int, path string) error {
	f := map[string]interface{}{"id": id, "unpacked_path": path}
	data, err := json.Marshal(f)
	if err != nil {
		return err
	}
	_, err = db.Exec("SELECT deckforge.upsert_pptx_file($1)", data)
	return err
}

func SaveSlide(db *sql.DB, s *Slide) error {
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}

	_, err = db.Exec("SELECT deckforge.upsert_collected_slide($1)", data)
	return err
}

func GetSlidesByFile(db *sql.DB, fileID int) ([]Slide, error) {
	var result []byte
	err := db.QueryRow("SELECT deckforge.get_slides_by_file($1)", fileID).Scan(&result)
	if err != nil {
		return nil, err
	}

	var slides []Slide
	if err := json.Unmarshal(result, &slides); err != nil {
		return nil, err
	}
	return slides, nil
}

func GetAllPPTX(db *sql.DB) ([]PPTXFile, error) {
	var result []byte
	err := db.QueryRow("SELECT deckforge.get_all_pptx()").Scan(&result)
	if err != nil {
		return nil, err
	}

	var files []PPTXFile
	if err := json.Unmarshal(result, &files); err != nil {
		return nil, err
	}
	return files, nil
}

func GetAllPPTXWithSlides(db *sql.DB) ([]PPTXWithSlides, error) {
	files, err := GetAllPPTX(db)
	if err != nil {
		return nil, err
	}

	var result []PPTXWithSlides
	for _, f := range files {
		slides, err := GetSlidesByFile(db, f.ID)
		if err != nil {
			return nil, err
		}
		result = append(result, PPTXWithSlides{
			PPTXFile: f,
			Slides:   slides,
		})
	}
	return result, nil
}

func GetTotalSlideCount(db *sql.DB) (int, error) {
	var count int
	err := db.QueryRow("SELECT COUNT(*) FROM deckforge.collected_slides").Scan(&count)
	return count, err
}

func ClearDatabase(db *sql.DB) error {
	// Delete in order to satisfy foreign keys
	_, err := db.Exec("DELETE FROM deckforge.placeholder_discovery")
	if err != nil {
		return err
	}
	_, err = db.Exec("DELETE FROM deckforge.collected_slides")
	if err != nil {
		return err
	}
	_, err = db.Exec("DELETE FROM deckforge.pptx_files")
	return err
}

func GetAIInsightCount(db *sql.DB) (int, error) {
	var count int
	// Counting slides with AI analysis or summaries
	err := db.QueryRow("SELECT COUNT(*) FROM deckforge.collected_slides WHERE ai_summary <> ''").Scan(&count)
	return count, err
}

func LogAIUsage(db *sql.DB, u *AIUsage) error {
	query := `
		INSERT INTO deckforge.ai_usage (provider, model, prompt_tokens, completion_tokens, total_tokens, cost)
		VALUES ($1, $2, $3, $4, $5, $6)
	`
	_, err := db.Exec(query, u.Provider, u.Model, u.PromptTokens, u.CompletionTokens, u.TotalTokens, u.Cost)
	return err
}

func GetTotalAICost(db *sql.DB) (float64, error) {
	var total float64
	err := db.QueryRow("SELECT COALESCE(SUM(cost), 0) FROM ai_usage").Scan(&total)
	return total, err
}

type DiscoveredPlaceholder struct {
	ID              int       `json:"id"`
	PPTXFileID      int       `json:"pptx_file_id"`
	SlideNumber     int       `json:"slide_number"`
	PlaceholderText string    `json:"placeholder_text"`
	MetadataKey     string    `json:"metadata_key"`
	TenantID        string    `json:"tenant_id"`
	DiscoveredAt    time.Time `json:"discovered_at"`
}

func SaveDiscoveredPlaceholder(db *sql.DB, dp *DiscoveredPlaceholder) error {
	data, err := json.Marshal(dp)
	if err != nil {
		return err
	}
	_, err = db.Exec("SELECT deckforge.save_placeholder_discovery($1)", data)
	return err
}

func GetDiscoveredPlaceholders(db *sql.DB) ([]DiscoveredPlaceholder, error) {
	rows, err := db.Query("SELECT id, pptx_file_id, slide_number, placeholder_text, metadata_key, discovered_at FROM deckforge.placeholder_discovery ORDER BY discovered_at DESC")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []DiscoveredPlaceholder
	for rows.Next() {
		var dp DiscoveredPlaceholder
		if err := rows.Scan(&dp.ID, &dp.PPTXFileID, &dp.SlideNumber, &dp.PlaceholderText, &dp.MetadataKey, &dp.TenantID, &dp.DiscoveredAt); err != nil {
			return nil, err
		}
		results = append(results, dp)
	}
	return results, nil
}

// SlideMind / DeckForge Helpers

func GetTenantByName(db *sql.DB, name string) (*Tenant, error) {
	var t Tenant
	query := "SELECT id, name, created_at FROM deckforge.tenants WHERE name = $1"
	err := db.QueryRow(query, name).Scan(&t.ID, &t.Name, &t.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

func GetThemeByName(db *sql.DB, tenantID, name string) (*Theme, error) {
	var t Theme
	query := "SELECT id, tenant_id, name, description, created_at FROM deckforge.themes WHERE tenant_id = $1 AND name = $2"
	err := db.QueryRow(query, tenantID, name).Scan(&t.ID, &t.TenantID, &t.Name, &t.Description, &t.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

func SaveSlideKnowledge(db *sql.DB, sk *SlideKnowledge) error {
	data, err := json.Marshal(sk)
	if err != nil {
		return err
	}
	_, err = db.Exec("SELECT deckforge.capture_slide_knowledge($1)", data)
	return err
}

func GetSlidesByTheme(db *sql.DB, tenantID, themeID string) ([]Slide, error) {
	query := `
		SELECT s.id, s.pptx_file_id, s.slide_number, s.png_path, s.content, s.style_info, s.ai_analysis, s.ai_summary, s.title, s.comments, s.tenant_id, s.htmx_content, s.created_at
		FROM deckforge.collected_slides s
		JOIN deckforge.pptx_files f ON s.pptx_file_id = f.id
		WHERE f.tenant_id = $1 AND f.theme_id = $2
		ORDER BY s.slide_number ASC
	`
	rows, err := db.Query(query, tenantID, themeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []Slide
	for rows.Next() {
		var s Slide
		err := rows.Scan(&s.ID, &s.PPTXFileID, &s.SlideNumber, &s.PNGPath, &s.Content, &s.StyleInfo, &s.AIAnalysis, &s.AISummary, &s.Title, &s.Comments, &s.TenantID, &s.HTMXContent, &s.CreatedAt)
		if err != nil {
			return nil, err
		}
		results = append(results, s)
	}
	return results, nil
}
