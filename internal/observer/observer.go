package observer

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"io"

	"github.com/fsnotify/fsnotify"
	"github.com/gnemet/DeckForge/internal/ai"
	"github.com/gnemet/DeckForge/internal/config"
	"github.com/gnemet/DeckForge/internal/database"
	"github.com/gnemet/DeckForge/internal/pptx"
)

type Observer struct {
	cfg         *config.Config
	db          *sql.DB
	aiClient    *ai.Client
	activeTasks int
	currentFile string
	totalQueued int
	startTime   time.Time
	mu          sync.Mutex
	LogChan     chan string
}

func NewObserver(cfg *config.Config, db *sql.DB, ai *ai.Client, logChan chan string) *Observer {
	return &Observer{
		cfg:      cfg,
		db:       db,
		aiClient: ai,
		LogChan:  logChan,
	}
}

func (o *Observer) log(format string, v ...interface{}) {
	msg := fmt.Sprintf(format, v...)
	log.Println(msg)
	if o.LogChan != nil {
		select {
		case o.LogChan <- msg:
		default:
			// fast non-blocking drop if buffer full
		}
	}
}

func (o *Observer) Start(ctx context.Context) error {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer watcher.Close()

	// Watch Base directory recursively
	baseDir := o.cfg.Application.Storage.Base
	if baseDir == "" {
		return fmt.Errorf("base storage directory not configured")
	}

	// Ensure base directory exists
	if err := os.MkdirAll(baseDir, 0755); err != nil {
		return fmt.Errorf("failed to create base directory: %v", err)
	}

	o.log("Recursively watching Base directory: %s", baseDir)
	err = filepath.Walk(baseDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			// Skip internal artifact folders to avoid infinite loops or noise if they are modified
			// But we need to watch Tenant/Theme/source
			return watcher.Add(path)
		}
		return nil
	})
	if err != nil {
		o.log("Failed to start recursive watch: %v", err)
	}

	o.log("Background observer started")

	// Initial scan
	o.log("Starting initial directory scan...")
	o.scanDirectory(baseDir, "full", "", false)

	for {
		select {
		case event, ok := <-watcher.Events:
			if !ok {
				return nil
			}
			if event.Has(fsnotify.Write) || event.Has(fsnotify.Create) {
				if strings.HasSuffix(strings.ToLower(event.Name), ".pptx") {
					// Check if it's in a 'source' folder
					tenantName, themeName := o.extractTenantAndTheme(event.Name)
					if tenantName == "" || themeName == "" {
						continue
					}

					if !strings.Contains(event.Name, string(os.PathSeparator)+"source"+string(os.PathSeparator)) {
						continue
					}

					o.log("Detected change in source: %s", event.Name)
					// Debounce/delay for file transfer to complete
					time.Sleep(2 * time.Second)
					o.ProcessFile(event.Name, "full", "", false)
				} else if event.Has(fsnotify.Create) {
					// If a new directory is created, watch it too
					if info, err := os.Stat(event.Name); err == nil && info.IsDir() {
						watcher.Add(event.Name)
					}
				}
			}
		case err, ok := <-watcher.Errors:
			if !ok {
				return nil
			}
			o.log("Watcher error: %v", err)

		case <-ctx.Done():
			return nil
		}
	}
}

func (o *Observer) scanDirectory(dir string, mode string, submode string, force bool) {
	o.log("Scanning directory recursively: %s [Mode: %s]", dir, mode)
	var pptxFiles []string
	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			o.log("Error walking path %s: %v", path, err)
			return nil // continue walking
		}
		if !info.IsDir() && strings.HasSuffix(strings.ToLower(info.Name()), ".pptx") {
			pptxFiles = append(pptxFiles, path)
		}
		return nil
	})
	if err != nil {
		o.log("Critical error during scan of %s: %v", dir, err)
	}

	o.mu.Lock()
	o.totalQueued += len(pptxFiles)
	o.mu.Unlock()

	for _, fullPath := range pptxFiles {
		// Only process if in a 'source' folder
		tenantName, themeName := o.extractTenantAndTheme(fullPath)
		if tenantName != "" && themeName != "" && strings.Contains(fullPath, string(os.PathSeparator)+"source"+string(os.PathSeparator)) {
			o.ProcessFile(fullPath, mode, submode, force)
		}
	}
}

func (o *Observer) ProcessSingleFile(filter string, mode string, submode string, force bool) {
	o.log("DEBUG: Base Storage is '%s'", o.cfg.Application.Storage.Base)
	// Filter can be an ID or a filename/path fragment
	var fileID int
	fmt.Sscanf(filter, "%d", &fileID)

	var path string
	if fileID != 0 {
		f, err := database.GetPPTXByID(o.db, fileID)
		if err != nil {
			o.log("Could not find file with ID %d: %v", fileID, err)
			return
		}
		path = f.OriginalFilePath
		if !filepath.IsAbs(path) {
			path = filepath.Join(o.cfg.Application.Storage.Base, path)
		}
	} else {
		// Try to find file by path fragment
		rows, err := o.db.Query("SELECT original_file_path FROM deckforge.pptx_files WHERE original_file_path LIKE $1 LIMIT 1", "%"+filter+"%")
		if err == nil {
			defer rows.Close()
			if rows.Next() {
				rows.Scan(&path)
			}
		}
		if path != "" && !filepath.IsAbs(path) && o.cfg.Application.Storage.Base != "" {
			path = filepath.Join(o.cfg.Application.Storage.Base, path)
		}
		if path == "" {
			// Try as absolute path
			if _, err := os.Stat(filter); err == nil {
				path = filter
			}
		}
	}

	if path == "" {
		o.log("Could not resolve file target: %s", filter)
		return
	}

	o.log("Processing single file [Mode: %s]: %s", mode, path)
	o.ProcessFile(path, mode, submode, force)
}

func (o *Observer) ScanBaseFolders(mode string, submode string, force bool) {
	o.log("Triggering incremental scan of base storage [Mode: %s, Submode: %s]...", mode, submode)
	o.scanDirectory(o.cfg.Application.Storage.Base, mode, submode, force)
}

func (o *Observer) UnpackFile(fileID int) error {
	f, err := database.GetPPTXByID(o.db, fileID)
	if err != nil {
		return err
	}

	tenantName, themeName := o.extractTenantAndTheme(f.OriginalFilePath)
	if tenantName == "" || themeName == "" {
		return fmt.Errorf("could not determine tenant/theme for file %d", fileID)
	}

	// For unpacking, we need the file locally.
	localWorkBase := filepath.Join(o.cfg.Application.Storage.Local, "work")
	os.MkdirAll(localWorkBase, 0755)
	localPPTXPath := filepath.Join(localWorkBase, f.Filename)

	// If path in DB is relative, resolve it to base storage
	absOriginalPath := f.OriginalFilePath
	if !filepath.IsAbs(absOriginalPath) {
		absOriginalPath = filepath.Join(o.cfg.Application.Storage.Base, f.OriginalFilePath)
	}

	o.log("Staging for unpack: %s", f.Filename)
	_, err = o.streamAndHash(absOriginalPath, localPPTXPath)
	if err != nil {
		return fmt.Errorf("failed to stage/hash %s from %s: %v", f.Filename, absOriginalPath, err)
	}
	defer os.Remove(localPPTXPath)

	// Resolve isolated unpack directory (re-using the logic from ProcessFile)
	// We might want to store cleanRelDir and cleanFilename in the DB too,
	// but for now we follow the existing resolver logic.

	// Refactoring the sanitization logic would be good, but let's keep it simple for now.
	cleanFilename := strings.TrimSuffix(f.Filename, filepath.Ext(f.Filename))
	sanitize := func(s string) string {
		return strings.Map(func(r rune) rune {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' {
				return r
			}
			return '_'
		}, s)
	}
	cleanFilename = sanitize(cleanFilename)

	sourceRoot := filepath.Join(o.cfg.Application.Storage.Base, tenantName, themeName, "source")
	relPPTX, _ := filepath.Rel(sourceRoot, f.OriginalFilePath)
	relSubDir := filepath.Dir(relPPTX)
	if relSubDir == "." {
		relSubDir = ""
	}
	var cleanRelParts []string
	for _, part := range strings.Split(relSubDir, string(os.PathSeparator)) {
		if part == "" || part == "." {
			continue
		}
		cleanRelParts = append(cleanRelParts, sanitize(part))
	}
	cleanRelDir := filepath.Join(cleanRelParts...)

	unpackSubPath := filepath.Join(cleanRelDir, cleanFilename)
	localUnpackDir := o.ResolvePath(tenantName, themeName, "unpack", unpackSubPath)

	o.log("Unpacking %d: %s -> %s", fileID, f.Filename, localUnpackDir)
	if err := pptx.UnpackPPTX(localPPTXPath, localUnpackDir); err != nil {
		return err
	}

	database.UpdatePPTXStatus(o.db, fileID, "unpacked")
	database.UpdatePPTXUnpackedPath(o.db, fileID, unpackSubPath)
	return nil
}

func (o *Observer) ProcessFile(path string, mode string, submode string, force bool) {
	if mode == "" {
		mode = "full"
	}
	filename := filepath.Base(path)

	o.mu.Lock()
	o.activeTasks++
	o.currentFile = filename
	o.startTime = time.Now()
	o.mu.Unlock()

	defer func() {
		o.mu.Lock()
		o.activeTasks--
		if o.activeTasks == 0 {
			o.currentFile = ""
		}
		if o.totalQueued > 0 {
			o.totalQueued--
		}
		o.mu.Unlock()
	}()

	// 0. Resolve relative path for DB lookups
	relPath, err := filepath.Rel(o.cfg.Application.Storage.Base, path)
	if err != nil {
		o.log("Failed to get relative path for %s: %v", path, err)
		return
	}
	dbRelPath := filepath.ToSlash(relPath)

	// Extract Tenant and Theme from path
	tenantName, themeName := o.extractTenantAndTheme(path)
	if tenantName == "" {
		tenantName = o.cfg.Tenant.Default
	}
	if tenantName == "" {
		tenantName = "BDO" // Absolute fallback
	}

	// Resolve Tenant and Theme IDs
	var tenantID string
	t, err := database.GetTenantByName(o.db, tenantName)
	if err != nil {
		o.log("Failed to resolve tenant %s: %v", tenantName, err)
		return
	}
	tenantID = t.ID

	var themeID *string
	if themeName != "" {
		th, err := database.GetThemeByName(o.db, tenantID, themeName)
		if err == nil && th != nil {
			themeID = &th.ID
		}
	}

	// 1. Prepare local SSD workspace
	localWorkBase := filepath.Join(o.cfg.Application.Storage.Local, "work")
	os.MkdirAll(localWorkBase, 0755)
	localPPTXPath := filepath.Join(localWorkBase, filename)

	// 2. Stream remote -> local + SHA256 in one pass
	o.log("Staging and hashing: %s [%s/%s]", filename, tenantName, themeName)
	checksum, err := o.streamAndHash(path, localPPTXPath)
	if err != nil {
		o.log("Failed to stage/hash %s: %v", filename, err)
		return
	}
	defer os.Remove(localPPTXPath)

	// 3. Process-once & Change detection (using the checksum from local)
	var existing *database.PPTXFile
	if !force {
		existing, err = database.GetPPTXByOriginalPath(o.db, path)
		if err == nil && existing != nil {
			if mode == "full" && existing.Status == "analized" && existing.Checksum == checksum && checksum != "" {
				o.log("File already processed and analized: %s. Skipping.", filename)
				return
			}
			if mode == "unpack" && (existing.Status == "unpacked" || existing.Status == "analized") && existing.Checksum == checksum && checksum != "" {
				o.log("File already unpacked: %s. Skipping.", filename)
				return
			}
			// If analyze mode, we proceed if status is not analized
			if mode == "analyze" && existing.Status == "analized" && existing.Checksum == checksum && checksum != "" {
				o.log("File already analized: %s. Skipping.", filename)
				return
			}
			o.log("Proceeding with %s: %s [Status: %s]", mode, filename, existing.Status)
		} else if checksum != "" {
			// Check for content match elsewhere (deduplication)
			existing, err = database.GetPPTXByChecksum(o.db, checksum)
			if err == nil && existing != nil {
				if mode == "full" && existing.Status == "analized" {
					o.log("Content already processed and analized at %s: %s. Skipping.", existing.OriginalFilePath, filename)
					return
				}
				if mode == "unpack" && (existing.Status == "unpacked" || existing.Status == "analized") {
					o.log("Content already unpacked at %s: %s. Skipping.", existing.OriginalFilePath, filename)
					return
				}
			}
		}
	}

	o.log("Processing (Local-First): %s", filename)
	processPath := localPPTXPath

	// 4. Extract Tags (Fast on local SSD)
	tags, err := pptx.ExtractTags(processPath)
	if err != nil {
		o.log("Failed to extract tags from %s: %v", filename, err)
	}

	// 5. Extraction (CPU/IO Intensive - Fast on local SSD)
	// In the absolute isolation model, we treat the sourceDir as the thematic root
	sourceRoot := filepath.Join(o.cfg.Application.Storage.Base, tenantName, themeName, "source")

	relPPTX, _ := filepath.Rel(sourceRoot, path)
	relSubDir := filepath.Dir(relPPTX)
	if relSubDir == "." {
		relSubDir = ""
	}

	cleanFilename := strings.TrimSuffix(filename, filepath.Ext(filename))
	// Standardize segments to avoid encoding issues
	sanitize := func(s string) string {
		return strings.Map(func(r rune) rune {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' {
				return r
			}
			return '_'
		}, s)
	}

	cleanFilename = sanitize(cleanFilename)
	// Sanitize relSubDir segments
	var cleanRelParts []string
	for _, part := range strings.Split(relSubDir, string(os.PathSeparator)) {
		if part == "" || part == "." {
			continue
		}
		cleanRelParts = append(cleanRelParts, sanitize(part))
	}
	cleanRelDir := filepath.Join(cleanRelParts...)

	// --- UNPACKING STEP ---
	unpackSubPath := filepath.Join(cleanRelDir, cleanFilename)
	localUnpackDir := o.ResolvePath(tenantName, themeName, "unpack", unpackSubPath)

	if mode == "full" || mode == "unpack" {
		if existing == nil || existing.Status == "uploaded" || existing.Status == "error" || force {
			o.log("Unpacking: %s -> %s", filename, localUnpackDir)
			if err := pptx.UnpackPPTX(processPath, localUnpackDir); err != nil {
				o.log("Failed to unpack %s: %v", filename, err)
				// We continue but log the error
			}
		}
	}

	if mode == "unpack" {
		// Update status and return if we only wanted to unpack
		if existing == nil {
			// Create basic record if it doesn't exist
			pptxFile := &database.PPTXFile{
				Filename:         filename,
				OriginalFilePath: path,
				UnpackedPath:     &unpackSubPath,
				Checksum:         checksum,
				Status:           "unpacked",
				Metadata:         []byte("{}"),
				TenantID:         tenantID,
			}
			database.SavePPTXMetadata(o.db, pptxFile)
		} else {
			database.UpdatePPTXStatus(o.db, existing.ID, "unpacked")
			database.UpdatePPTXUnpackedPath(o.db, existing.ID, unpackSubPath)
		}
		o.log("Unpack completed for %s", filename)
		return
	}

	// mode is either analyze or full from here on

	// --- ANALYSIS STEPS ---
	var pngFiles []string
	var slideDataMap map[int]pptx.SlideData

	shouldRunThumbnail := (mode == "full" || mode == "analyze") && (submode == "" || submode == "thumbnail" || submode == "full")
	shouldRunText := (mode == "full" || mode == "analyze") && (submode == "" || submode == "text" || submode == "placeholder" || submode == "full" || submode == "ai")
	shouldRunAI := (mode == "full" || mode == "analyze") && (submode == "" || submode == "ai" || submode == "full")

	// 1. Resolve shared thumbnail directory for the theme
	// The user wants: thumbnails/{pptx_filename}/slide-000N.png
	localThumbDir := o.ResolvePath(tenantName, themeName, "thumbnails", cleanFilename)
	os.RemoveAll(localThumbDir) // Clear any previous leftovers for this specific file
	os.MkdirAll(localThumbDir, 0755)

	if shouldRunThumbnail {
		o.log("Generating slide thumbnails in: %s", localThumbDir)
		if pngs, err := pptx.ExtractSlidesToPNG(processPath, localThumbDir, os.TempDir()); err != nil {
			o.log("Failed to extract thumbnails from %s: %v", filename, err)
		} else {
			pngFiles = pngs
		}
	}

	if shouldRunText {
		o.log("Extracting slide content: %s", filename)
		if sdm, err := pptx.ExtractSlideContent(processPath); err != nil {
			o.log("Failed to extract slide content from %s: %v", filename, err)
		} else {
			slideDataMap = sdm
			o.log("Extracted %d slides from %s", len(slideDataMap), filename)
		}
	}

	// Try to find comments for this file
	allComments := make(map[int][]pptx.Comment)
	for i, data := range slideDataMap {
		if len(data.Comments) > 0 {
			allComments[i] = data.Comments
		}
	}

	metadata := map[string]interface{}{
		"tags":         tags,
		"comments":     allComments,
		"processed_at": time.Now().Format(time.RFC3339),
	}
	metadataJSON, _ := json.Marshal(metadata)

	if len(allComments) > 0 {
		o.log("Found comments on %d slides in %s", len(allComments), filename)
	}

	// Database persist
	thumbsDir := filepath.ToSlash(filepath.Join(tenantName, themeName, "thumbnails"))
	pptxFile := &database.PPTXFile{
		Filename:         filename,
		OriginalFilePath: path,
		ThumbnailDirPath: &thumbsDir, // Pointing to thematic thumbnails root: {tenant}/{theme}/thumbnails
		UnpackedPath:     nil,        // We delete unpack folder after use
		Metadata:         metadataJSON,
		IsTemplate:       len(tags) > 0,
		Checksum:         checksum,
		Status:           "unpacked",
		TenantID:         tenantID,
		ThemeID:          themeID,
	}

	// Check for existing file by Checksum and Path
	var fileID int
	var existingStatus string
	err = o.db.QueryRow("SELECT id, status FROM deckforge.pptx_files WHERE checksum = $1 AND original_file_path = $2", checksum, dbRelPath).Scan(&fileID, &existingStatus)
	if err == nil {
		o.log("Found existing record for %s (ID: %d, Status: %s)", filename, fileID, existingStatus)
	}
	if err == nil && !force {
		// Logic to skip if already done
		if mode == "full" && existingStatus == "analyzed" {
			o.log("File %s (checksum: %s) already exists and analyzed (ID: %d). Skipping.", filename, checksum, fileID)
			o.finalizeFile(path, fileID)
			return
		}
		if mode == "unpack" && (existingStatus == "unpacked" || existingStatus == "analyzed") {
			o.log("File %s (checksum: %s) already exists and unpacked/analyzed (ID: %d). Skipping.", filename, checksum, fileID)
			o.finalizeFile(path, fileID)
			return
		}
		// Special submode bypass: if we are running a SUBMODE, we proceed even if analized if NOT force?
		// User probably wants to RE-RUN specifically the thumbnails if they call --submode thumbnail.
		// But let's assume if it's already analized and they didn't pass --force, they might want to skip.
		// Actually, if submode is provided, we should probably proceed to overwrite that specific part.
		if submode == "" {
			if mode == "analyze" && existingStatus == "analyzed" {
				o.log("File %s (checksum: %s) already exists and analyzed (ID: %d). Skipping.", filename, checksum, fileID)
				o.finalizeFile(path, fileID)
				return
			}
		}
	}

	// Fallback to filename/path check if checksum logic didn't hit
	var existingID int
	if fileID == 0 {
		err = o.db.QueryRow("SELECT id FROM deckforge.pptx_files WHERE filename = $1 AND original_file_path = $2", filename, path).Scan(&existingID)
		if err == nil && existingID != 0 && !force {
			if submode == "" {
				o.log("File %s already exists by path (ID: %d). Skipping.", filename, existingID)
				o.finalizeFile(path, existingID)
				return
			}
		}
		if err == nil {
			fileID = existingID
		}
	}

	if fileID == 0 {
		fileID, err = database.SavePPTXMetadata(o.db, pptxFile)
		if err != nil {
			o.log("Failed to save metadata to DB: %v", err)
			return
		}
	} else {
		// Update existing (e.g. metadata or checksum if it was empty)
		// Only update metadata if we actually ran the extraction steps
		if shouldRunText || shouldRunThumbnail {
			_, err = o.db.Exec("UPDATE deckforge.pptx_files SET metadata = $1, is_template = $2, thumbnail_dir_path = $3, checksum = $4, theme_id = $5 WHERE id = $6",
				pptxFile.Metadata, pptxFile.IsTemplate, pptxFile.ThumbnailDirPath, pptxFile.Checksum, pptxFile.ThemeID, fileID)
			if err != nil {
				o.log("Failed to update metadata in DB: %v", err)
			}
		}

		// Only clear slides if we are re-extracting text
		if shouldRunText {
			_, _ = o.db.Exec("DELETE FROM deckforge.collected_slides WHERE pptx_file_id = $1", fileID)
		}
	}

	// Save slides and collect summaries
	var slideSummaries []string
	ctx := context.Background()

	if shouldRunThumbnail && !shouldRunText && slideDataMap == nil {
		// If we only have PNGs but no slideDataMap, we still create/update slides records for thumbnails
		for i, png := range pngFiles {
			slideNum := i + 1
			// Store path relative to the thematic thumbnails root: {filename}/slide-000N.png
			dbPNGPath := filepath.Join(cleanFilename, filepath.Base(png))

			// Try to update existing slide record or create new
			_, err = o.db.Exec(`
				INSERT INTO deckforge.collected_slides (pptx_file_id, slide_number, png_path, content, style_info, ai_analysis, ai_summary, title, comments, tenant_id)
				VALUES ($1, $2, $3, '', '{}', '{}', '', '', '', $4)
				ON CONFLICT (pptx_file_id, slide_number) DO UPDATE SET png_path = EXCLUDED.png_path`,
				fileID, slideNum, dbPNGPath, tenantID)
			// If it's the first slide, update the PPTX preview
			if slideNum == 1 && png != "" {
				if b64, err := o.toBase64(png); err == nil {
					o.db.Exec("UPDATE deckforge.pptx_files SET preview_thumbnail = $1 WHERE id = $2", b64, fileID)
				}
			}

			if err != nil {
				o.log("Failed to sync thumbnail for slide %d: %v", slideNum, err)
			}
		}
	}

	if shouldRunText {
		// Iterate over slideDataMap (which is populated if shouldRunText is true)
		// We sort the keys to process slides in order
		var slideNums []int
		for k := range slideDataMap {
			slideNums = append(slideNums, k)
		}
		sort.Ints(slideNums)

		o.log("Saving %d slides for file %d...", len(slideNums), fileID)
		for _, slideNum := range slideNums {
			data := slideDataMap[slideNum]
			content := data.Text
			styleJSON := []byte("{}")
			slideSummary := ""
			slideTitle := fmt.Sprintf("Slide %d", slideNum)

			if sj, err := json.Marshal(data.Styles); err == nil {
				styleJSON = sj
			}

			// Generate slide summary & title ONLY if AI is enabled and shouldRunAI is true
			var aiEnabledVal float64
			o.db.QueryRow("SELECT value FROM search_settings WHERE key = 'ai_insights_enabled'").Scan(&aiEnabledVal)
			aiEnabled := aiEnabledVal > 0.5 || (aiEnabledVal == 0 && o.cfg.AI.Enabled)

			if shouldRunAI && content != "" && aiEnabled {
				// Summary
				result, err := o.aiClient.SummarizeText(ctx, content)
				if err == nil {
					slideSummary = result.Content
					slideSummaries = append(slideSummaries, result.Content)
				} else {
					o.log("Failed to summarize slide %d of %s: %v", slideNum, filename, err)
				}
			}

			// Title generation
			if shouldRunAI && aiEnabled {
				if len(data.Comments) > 0 {
					var commentTexts []string
					for _, c := range data.Comments {
						commentTexts = append(commentTexts, c.Text)
					}
					fullComments := strings.Join(commentTexts, " | ")
					rawTitleResult, err := o.aiClient.ExtractTitleFromComments(ctx, fullComments)
					if err == nil && rawTitleResult.Content != "" {
						slideTitle = fmt.Sprintf("%d. %s", slideNum, rawTitleResult.Content)
					}
				} else if content != "" {
					rawTitleResult, err := o.aiClient.ExtractSlideTitle(ctx, content)
					if err == nil && rawTitleResult.Content != "" {
						slideTitle = fmt.Sprintf("%d. %s", slideNum, rawTitleResult.Content)
					}
				}
			}

			comments := ""
			var commentTexts []string
			for _, c := range data.Comments {
				commentTexts = append(commentTexts, c.Text)
			}
			comments = strings.Join(commentTexts, " | ")

			// Get PNG Path for this slide if it exists
			dbPNGPath := ""
			if shouldRunThumbnail && len(pngFiles) >= slideNum {
				png := pngFiles[slideNum-1]
				dbPNGPath = filepath.Join(cleanFilename, filepath.Base(png))

				// Update presentation preview as Base64 if first slide
				if slideNum == 1 {
					if b64, err := o.toBase64(png); err == nil {
						o.db.Exec("UPDATE deckforge.pptx_files SET preview_thumbnail = $1 WHERE id = $2", b64, fileID)
					} else {
						o.log("Base64 conversion failed for dashboard preview: %v", err)
					}
				}
			}

			err = database.SaveSlide(o.db, &database.Slide{
				PPTXFileID:  fileID,
				SlideNumber: slideNum,
				PNGPath:     dbPNGPath,
				Content:     content,
				StyleInfo:   styleJSON,
				AIAnalysis:  []byte("{}"),
				AISummary:   slideSummary,
				Title:       slideTitle,
				Comments:    comments,
				TenantID:    tenantID,
			})
			if err != nil {
				o.log("Failed to save slide %d: %v", slideNum, err)
			}

			// --- PLACEHOLDER DISCOVERY ---
			if submode == "placeholder" || submode == "" || mode == "full" {
				tagRegex := regexp.MustCompile(`{{(.*?)}}`)
				matches := tagRegex.FindAllStringSubmatch(content, -1)
				for _, match := range matches {
					if len(match) > 1 {
						tag := strings.TrimSpace(match[1])
						dp := &database.DiscoveredPlaceholder{
							PPTXFileID:      fileID,
							SlideNumber:     slideNum,
							PlaceholderText: tag,
							MetadataKey:     o.slugify(tag),
						}
						database.SaveDiscoveredPlaceholder(o.db, dp)
					}
				}
			}

			// --- SLIDEMIND KNOWLEDGE POPULATION ---
			if mode == "full" || (mode == "analyze" && (submode == "" || submode == "ai")) {
				tenantObj, _ := database.GetTenantByName(o.db, tenantName)
				if tenantObj != nil {
					themeObj, _ := database.GetThemeByName(o.db, tenantObj.ID, themeName)
					if themeObj != nil {
						sk := &database.SlideKnowledge{
							TenantID:    tenantObj.ID,
							ThemeID:     themeObj.ID,
							PPTXFileID:  fileID,
							SlideNumber: slideNum,
							Content:     content,
							AISummary:   slideSummary,
							Metadata:    []byte("{}"),
						}
						database.SaveSlideKnowledge(o.db, sk)
					}
				}
			}
		}
	}

	// presentation summary & title
	if shouldRunAI {
		var aiEnabledVal float64
		o.db.QueryRow("SELECT value FROM search_settings WHERE key = 'ai_insights_enabled'").Scan(&aiEnabledVal)
		aiEnabled := aiEnabledVal > 0.5 || (aiEnabledVal == 0 && o.cfg.AI.Enabled)

		if aiEnabled && len(slideSummaries) > 0 {
			fullTextForSummary := strings.Join(slideSummaries, "\n")
			overallSummaryResult, err := o.aiClient.SummarizeText(ctx, "This is a summary of all slides in a presentation. Please provide a high-level summary of the entire deck: \n"+fullTextForSummary)
			if err == nil {
				database.UpdatePPTXSummary(o.db, fileID, overallSummaryResult.Content)
			}
		}

		if aiEnabled && slideDataMap != nil {
			if data, ok := slideDataMap[1]; ok && data.Text != "" {
				titleResult, err := o.aiClient.ExtractTitle(ctx, data.Text)
				if err == nil && titleResult.Content != "" {
					database.UpdatePPTXTitle(o.db, fileID, titleResult.Content)
				}
			}
		}
	}

	// Update Status to analyzed
	if mode == "full" || mode == "analyze" {
		database.UpdatePPTXStatus(o.db, fileID, "analyzed")
	}

	if (submode == "htmx" || submode == "full" || (mode == "full" && submode == "")) && slideDataMap != nil {
		o.log("HTMX generation: %s", filename)
		o.generateHTMX(fileID, slideDataMap)
	}

	// Cleanup unpacked folder if it was created
	if unpackSubPath != "" {
		o.log("Cleaning up unpacked XML data...")
		os.RemoveAll(filepath.Join(o.cfg.Application.Storage.Base, unpackSubPath))
	}

	o.finalizeFile(path, fileID)
}

func (o *Observer) toBase64(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	mimeType := "image/png"
	if strings.HasSuffix(strings.ToLower(path), ".jpg") || strings.HasSuffix(strings.ToLower(path), ".jpeg") {
		mimeType = "image/jpeg"
	}
	encoded := base64.StdEncoding.EncodeToString(data)
	return fmt.Sprintf("data:%s;base64,%s", mimeType, encoded), nil
}

func (o *Observer) finalizeFile(path string, fileID int) {
	// In the absolute isolation model, we don't move files to a global template folder.
	// They stay in their source folder or get processed into the thematic slidemind/seed folders.
	o.log("Keeping processed file in thematic context: %s", path)

	// Update database path - Ensure it's stored relative to the BASE_PATH
	relPath, err := filepath.Rel(o.cfg.Application.Storage.Base, path)
	if err == nil {
		_, err = o.db.Exec("UPDATE deckforge.pptx_files SET original_file_path = $1 WHERE id = $2", filepath.ToSlash(relPath), fileID)
		if err != nil {
			o.log("Failed to update file path in DB: %v", err)
		}
	}
}

func (o *Observer) ResolvePath(tenant, theme, category string, subPath ...string) string {
	base := filepath.Join(o.cfg.Application.Storage.Base, tenant, theme, category)
	if len(subPath) > 0 {
		return filepath.Join(base, filepath.Join(subPath...))
	}
	return base
}

func (o *Observer) ReprocessAll() {
	o.mu.Lock()
	o.activeTasks++
	o.startTime = time.Now()
	o.mu.Unlock()

	defer func() {
		o.mu.Lock()
		o.activeTasks--
		o.mu.Unlock()
	}()

	o.log("STARTING FULL REPROCESS: Resetting state...")

	// 1. Clear database
	if err := database.ClearDatabase(o.db); err != nil {
		o.log("CRITICAL: Failed to clear database during reprocess: %v", err)
		return
	}

	// 2. Clear Stage/Template - In the new model, this means scanning all themes
	// and potentially moving files around, but for now we just reset the DB and scan everything.
	o.log("Triggering full thematic scan...")
	o.mu.Lock()
	o.totalQueued = 0
	o.mu.Unlock()

	o.scanDirectory(o.cfg.Application.Storage.Base, "full", "", true)
}

func (o *Observer) GetStatus() (bool, string, int, time.Time) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.activeTasks > 0, o.currentFile, o.totalQueued, o.startTime
}

func (o *Observer) streamAndHash(src, dst string) (string, error) {
	in, err := os.Open(src)
	if err != nil {
		return "", err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return "", err
	}
	defer out.Close()

	hash := sha256.New()
	mw := io.MultiWriter(out, hash)

	_, err = io.Copy(mw, in)
	if err != nil {
		return "", err
	}

	return hex.EncodeToString(hash.Sum(nil)), out.Close()
}

func (o *Observer) extractTenantAndTheme(path string) (string, string) {
	// If it's already a relative path like "Tenant/Theme/source/file.pptx"
	// we just split it.
	parts := strings.Split(filepath.ToSlash(path), "/")

	// If it's an absolute path, try to make it relative to storage base
	if filepath.IsAbs(path) {
		root := o.cfg.Application.Storage.Base
		if root != "" {
			if rel, err := filepath.Rel(root, path); err == nil {
				parts = strings.Split(filepath.ToSlash(rel), "/")
			}
		}
	}

	// Structure: {Tenant}/{Theme}/source/...
	if len(parts) >= 2 {
		return parts[0], parts[1]
	}
	return "", ""
}

func (o *Observer) generateHTMX(fileID int, slideDataMap map[int]pptx.SlideData) {
	o.log("Generating HTMX representation for WYSIWYG...")
	for num, data := range slideDataMap {
		// Fetch Base64 thumbnail from DB for background
		var base64PNG string
		o.db.QueryRow("SELECT png_path FROM deckforge.collected_slides WHERE pptx_file_id = $1 AND slide_number = $2", fileID, num).Scan(&base64PNG)

		// Type assertion for Styles
		styles, ok := data.Styles.(*pptx.JSONSlide)
		if !ok || styles == nil {
			o.log("Skip HTMX for slide %d: invalid styles data", num)
			continue
		}

		// Create a basic HTMX representation: a div container with Base64 background
		var sb strings.Builder
		bgStyle := ""
		if strings.HasPrefix(base64PNG, "data:image") {
			bgStyle = fmt.Sprintf("background-image:url('%s'); background-size:cover;", base64PNG)
		} else {
			bgStyle = "background:#fff;"
		}

		sb.WriteString(fmt.Sprintf("<div class='slide-container' style='position:relative; width:100%%; aspect-ratio:16/9; %s overflow:hidden;'>", bgStyle))

		// Map shapes/styles to simple divs
		for _, s := range styles.Shapes {
			sb.WriteString(fmt.Sprintf("<div class='shape' style='position:absolute; left:%f%%; top:%f%%; width:%f%%; height:%f%%; border:1px solid rgba(204,204,204,0.3); font-size:0.8em; overflow:hidden;'>",
				s.X, s.Y, s.W, s.H))
			// We don't necessarily want labels for background shapes if they are redundant with the image
			// sb.WriteString(s.Text)
			sb.WriteString("</div>")
		}

		sb.WriteString("</div>")

		// Save to collected_slides using explicit schema
		_, err := o.db.Exec("UPDATE deckforge.collected_slides SET htmx_content = $1 WHERE pptx_file_id = $2 AND slide_number = $3",
			sb.String(), fileID, num)
		if err != nil {
			o.log("Failed to save HTMX for slide %d: %v", num, err)
		}
	}
}

func (o *Observer) SummarizeTheme(tenantID, themeID string) error {
	o.log("Starting theme-wide summarization for theme %s", themeID)
	slides, err := database.GetSlidesByTheme(o.db, tenantID, themeID)
	if err != nil {
		return err
	}

	// Group slides by title (normalized)
	groups := make(map[string][]database.Slide)
	for _, s := range slides {
		t := o.slugify(s.Title)
		if t == "" {
			t = fmt.Sprintf("slide_%d", s.SlideNumber)
		}
		groups[t] = append(groups[t], s)
	}

	for title, group := range groups {
		o.log("Summarizing group: %s (%d slides)", title, len(group))
		var contents []string
		var refIDs []int
		for _, s := range group {
			contents = append(contents, s.Content)
			refIDs = append(refIDs, s.ID)
		}

		// Call AI to merge
		res, err := o.aiClient.MergeSlides(context.Background(), contents)
		if err != nil {
			o.log("AI merge failed for %s: %v", title, err)
			continue
		}

		// AI returns JSON: {seed_content: "...", placeholders: [...]}
		var aiRes struct {
			SeedContent  string          `json:"seed_content"`
			Placeholders json.RawMessage `json:"placeholders"`
		}
		// Clean content in case of markdown blocks
		cleanJSON := res.Content
		if strings.HasPrefix(cleanJSON, "```json") {
			cleanJSON = strings.TrimPrefix(cleanJSON, "```json")
			cleanJSON = strings.TrimSuffix(cleanJSON, "```")
		}
		cleanJSON = strings.TrimSpace(cleanJSON)

		if err := json.Unmarshal([]byte(cleanJSON), &aiRes); err != nil {
			o.log("AI returned invalid JSON for %s: %s", title, cleanJSON)
			continue
		}

		// Save to summarized_slides
		summarized := &database.SummarizedSlide{
			TenantID:          tenantID,
			ThemeID:           themeID,
			Title:             group[0].Title, // Use first slide's title as base
			SeedContent:       aiRes.SeedContent,
			Placeholders:      aiRes.Placeholders,
			ReferenceSlideIDs: refIDs,
		}
		if err := database.SaveSummarizedSlide(o.db, summarized); err != nil {
			o.log("Failed to save summarized slide %s: %v", title, err)
		}
	}

	// --- EXPORT TO FILESYSYTEM ---
	// Fetch all again to ensure we have the full picture
	allSummarized, err := database.GetSummarizedSlidesByTheme(o.db, tenantID, themeID)
	if err == nil && len(allSummarized) > 0 {
		var tenantName, themeName string
		o.db.QueryRow("SELECT name FROM deckforge.tenants WHERE id = $1", tenantID).Scan(&tenantName)
		o.db.QueryRow("SELECT name FROM deckforge.themes WHERE id = $1", themeID).Scan(&themeName)

		seedDir := o.ResolvePath(tenantName, themeName, "seed")
		os.MkdirAll(seedDir, 0755)

		var templateContent []string
		var allPlaceholders []interface{}

		for _, s := range allSummarized {
			templateContent = append(templateContent, fmt.Sprintf("# %s\n\n%s", s.Title, s.SeedContent))
			var pls []interface{}
			if err := json.Unmarshal(s.Placeholders, &pls); err == nil {
				allPlaceholders = append(allPlaceholders, pls...)
			}
		}

		templatePath := filepath.Join(seedDir, "template.md")
		dataPath := filepath.Join(seedDir, "data.json")

		os.WriteFile(templatePath, []byte(strings.Join(templateContent, "\n\n---\n\n")), 0644)
		dataJSON, _ := json.MarshalIndent(allPlaceholders, "", "  ")
		os.WriteFile(dataPath, dataJSON, 0644)

		o.log("Exported thematic artifacts to: %s", seedDir)
	}

	o.log("Theme summarization completed.")
	return nil
}

func (o *Observer) slugify(s string) string {
	s = strings.ToLower(s)
	s = regexp.MustCompile(`[^a-z0-9]+`).ReplaceAllString(s, "_")
	return strings.Trim(s, "_")
}
