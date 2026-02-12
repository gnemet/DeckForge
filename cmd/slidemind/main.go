package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/gnemet/DeckForge/internal/ai"
	"github.com/gnemet/DeckForge/internal/config"
	"github.com/gnemet/DeckForge/internal/database"
	"github.com/gnemet/DeckForge/internal/observer"
	_ "github.com/lib/pq"
)

func main() {
	scanCmd := flag.NewFlagSet("scan", flag.ExitOnError)
	force := scanCmd.Bool("force", false, "Force re-processing of all files")
	mode := scanCmd.String("mode", "full", "Processing mode: unpack, analyze, full")
	submode := scanCmd.String("submode", "", "Granular sub-mode for analyze: thumbnail, text, placeholder, htmx, ai")
	fileFilter := scanCmd.String("file", "", "Target specific file by ID or path fragment")

	statusCmd := flag.NewFlagSet("status", flag.ExitOnError)

	if len(os.Args) < 2 {
		fmt.Println("Expected 'scan' or 'status' subcommands")
		os.Exit(1)
	}

	cfg, err := config.LoadConfig()
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	db, err := sql.Open("postgres", cfg.Database.GetConnectStr())
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer db.Close()

	// Initializing AI Client
	aiClient := ai.NewClient(cfg)
	logChan := make(chan string, 100)
	go func() {
		for msg := range logChan {
			fmt.Printf("[Observer] %s\n", msg)
		}
	}()

	obs := observer.NewObserver(cfg, db, aiClient, logChan)

	switch os.Args[1] {
	case "scan":
		scanCmd.Parse(os.Args[2:])
		fmt.Printf("Starting SlideMind scan [Mode: %s, Submode: %s, File: %s, Force: %v]...\n", *mode, *submode, *fileFilter, *force)

		if *fileFilter != "" {
			obs.ProcessSingleFile(*fileFilter, *mode, *submode, *force)
		} else if *force {
			obs.ReprocessAll()
		} else {
			obs.ScanBaseFolders(*mode, *submode, false)
		}

	case "status":
		statusCmd.Parse(os.Args[2:])
		files, err := database.GetAllPPTX(db)
		if err != nil {
			log.Fatalf("Failed to fetch files: %v", err)
		}

		fmt.Printf("\n--- SlideMind Process Status ---\n")
		fmt.Printf("%-3s | %-20s | %-10s | %-s\n", "ID", "Filename", "Status", "Checksum")
		fmt.Println("--------------------------------------------------------------------------------")
		for _, f := range files {
			fmt.Printf("%-3d | %-20.20s | %-10s | %-s\n", f.ID, f.Filename, f.Status, f.Checksum)
		}
		fmt.Println("--------------------------------------------------------------------------------")

	case "unpack":
		// Deprecated in favor of 'scan --mode unpack --file <ID>'
		if len(os.Args) < 3 {
			fmt.Println("Usage: slidemind unpack <fileID>")
			os.Exit(1)
		}
		var fileID int
		fmt.Sscanf(os.Args[2], "%d", &fileID)
		if fileID == 0 {
			log.Fatalf("Invalid file ID: %s", os.Args[2])
		}

		fmt.Printf("Unpacking file ID %d...\n", fileID)
		if err := obs.UnpackFile(fileID); err != nil {
			log.Fatalf("Unpack failed: %v", err)
		}
		fmt.Println("Unpack successful.")

	case "summarize":
		summarizeCmd := flag.NewFlagSet("summarize", flag.ExitOnError)
		tenantArg := summarizeCmd.String("tenant", "", "Tenant name")
		themeArg := summarizeCmd.String("theme", "", "Theme name")
		summarizeCmd.Parse(os.Args[2:])

		if *tenantArg == "" || *themeArg == "" {
			fmt.Println("Usage: slidemind summarize --tenant <name> --theme <name>")
			os.Exit(1)
		}

		fmt.Printf("Summarizing theme '%s' for tenant '%s'...\n", *themeArg, *tenantArg)
		t, err := database.GetTenantByName(db, *tenantArg)
		if err != nil {
			log.Fatalf("Tenant not found: %s", *tenantArg)
		}
		th, err := database.GetThemeByName(db, t.ID, *themeArg)
		if err != nil {
			log.Fatalf("Theme not found: %s", *themeArg)
		}

		if err := obs.SummarizeTheme(t.ID, th.ID); err != nil {
			log.Fatalf("Summarization failed: %v", err)
		}
		fmt.Println("Summarization successful.")

	default:
		fmt.Println("Expected 'scan', 'status' or 'summarize' subcommands")
		os.Exit(1)
	}
}

// Note: I need to add ScanBaseFolders to Observer to just scan without clearing.
