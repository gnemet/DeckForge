package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/gnemet/DeckForge/internal/config"
	"github.com/gnemet/DeckForge/internal/pptx"
	_ "github.com/lib/pq"
)

func resolvePath(cfg *config.Config, relPath string) string {
	if filepath.IsAbs(relPath) {
		return relPath
	}
	// In the new model, all relative paths are from Storage.Base
	return filepath.Join(cfg.Application.Storage.Base, relPath)
}

func main() {
	cfg, err := config.LoadConfig()
	if err != nil {
		log.Fatal(err)
	}

	db, err := sql.Open("postgres", cfg.Database.GetConnectStr())
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	rows, err := db.Query("SELECT id, filename, original_file_path, thumbnail_dir_path FROM deckforge.pptx_files")
	if err != nil {
		log.Fatal(err)
	}
	defer rows.Close()

	for rows.Next() {
		var id int
		var filename, originalPath, thumbDirPath string
		if err := rows.Scan(&id, &filename, &originalPath, &thumbDirPath); err != nil {
			log.Printf("Error scanning row: %v", err)
			continue
		}

		absOriginalPath := resolvePath(cfg, originalPath)
		// For regenerate, we assume thumbnails are also relative to Base
		absThumbDir := filepath.Join(cfg.Application.Storage.Base, thumbDirPath)
		checkFile := filepath.Join(absThumbDir, "slide-0001.png")

		if _, err := os.Stat(checkFile); os.IsNotExist(err) {
			if _, err := os.Stat(absOriginalPath); os.IsNotExist(err) {
				log.Printf("ID %d: CANNOT REGENERATE. Original file not found at %s", id, absOriginalPath)
				continue
			}

			fmt.Printf("ID %d: Thumbnail missing for %s. Regenerating from %s...\n", id, filename, absOriginalPath)

			// Ensure thumb dir exists
			os.MkdirAll(absThumbDir, 0755)

			_, err := pptx.ExtractSlidesToPNG(absOriginalPath, absThumbDir, os.TempDir())
			if err != nil {
				log.Printf("ID %d: Failed to regenerate: %v", id, err)
			} else {
				fmt.Printf("ID %d: Successfully regenerated thumbnails.\n", id)
			}
		}
	}
}
