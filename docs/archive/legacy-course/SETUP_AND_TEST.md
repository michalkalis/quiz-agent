# Setup and Testing Guide

Complete guide to set up and test the enhanced quiz question system.

---

## ✅ What's Been Implemented

1. **Storage Layer** - Enhanced with review workflow support
2. **Web UI** - Complete question management interface
3. **Import Functionality** - Upload ChatGPT JSON
4. **Review Workflow** - Rate and approve questions
5. **Quiz App Integration** - Only uses approved questions
6. **Advanced Generation** - Best-of-N with LLM judge

---

## 🚀 Quick Start

### Step 1: Install Dependencies

```bash
cd /Users/michalkalis/Library/CloudStorage/GoogleDrive-michal.kalis@gmail.com/My\ Drive/_projects/ai-developer-course/code/quiz-agent

# Install jinja2 for web templates (if not already installed)
pip install jinja2
```

### Step 2: Import Your Existing Rated Questions

```bash
# Import high-quality questions from pub-quiz-finetuning
cd /Users/michalkalis/Library/CloudStorage/GoogleDrive-michal.kalis@gmail.com/My\ Drive/_projects/ai-developer-course/code/quiz-agent

python scripts/import_rated_questions.py
```

This will:
- Import questions from your `pub-quiz-finetuning/data/dpo_training/high_quality.json`
- Mark them as "approved"
- Skip duplicates automatically
- Give you an instant library of approved questions

### Step 3: Start the Question Generator Service

```bash
cd apps/question-generator
uvicorn app.main:app --port 8001 --reload
```

### Step 4: Open the Web UI

Open your browser to: **http://localhost:8001/web**

You should see:
- Home page with your imported questions
- Statistics showing approved count
- All questions marked as "Approved"

---

## 📱 Testing the Complete System

### Test 1: Web UI Navigation

1. Visit http://localhost:8001/web
2. **Home page** - Should show imported questions
3. **Import page** - Ready to import ChatGPT JSON
4. **Review page** - Should show "No questions to review" (all imported are approved)
5. **Statistics page** - Shows counts and progress

### Test 2: Import ChatGPT Questions

1. Go to **Import** page
2. Copy this test JSON:

```json
{
  "questions": [
    {
      "question": "Which animal can sleep while standing up by locking its legs?",
      "correct_answer": "Horse",
      "alternative_answers": ["horse", "horses"],
      "topic": "Biology",
      "difficulty": "easy",
      "tags": ["animals", "biology"]
    }
  ]
}
```

3. Paste and click "Import Questions"
4. Should see "Successfully imported 1 questions!"
5. Go to **Home** page - new question shows as "Pending"

### Test 3: Review Questions

1. Go to **Review** page
2. Should see the test question
3. Rate it on the 4 dimensions (use sliders)
4. Click "Approve"
5. Redirects back to review list
6. Go to **Home** - question now shows as "Approved"

### Test 4: Statistics

1. Go to **Statistics** page
2. Should see updated counts
3. Progress bars showing review completion
4. Average quality score

### Test 5: Quiz App Integration

```bash
# In another terminal, start the quiz app
cd apps/quiz-agent
python -m cli.terminal_ui
```

1. Start a quiz
2. It should ONLY show approved questions
3. The test question (if approved) should be available
4. No pending/rejected questions should appear

---

## 🔄 Complete Workflow Example

### Generate Questions with ChatGPT

1. Open ChatGPT app
2. Use the prompt from `CHATGPT_GENERATION_GUIDE.md`
3. Ask: "Generate 5 medium difficulty science questions"
4. Copy the JSON response

### Import to System

1. Go to http://localhost:8001/web/import
2. Paste JSON
3. Click "Import Questions"
4. Questions added as "pending_review"

### Review Questions

1. Go to http://localhost:8001/web/review
2. For each question:
   - Read carefully
   - Rate on 4 dimensions (1-5)
   - Click "Approve", "Needs Revision", or "Reject"
3. System auto-advances to next pending question

### Use in Quiz

1. Start quiz app
2. Approved questions are available
3. Pending/rejected questions are excluded

---

## 🧪 Advanced Generation Testing

### Test Advanced API (Best-of-N)

```bash
# Generate 10 questions (actually generates 30, selects best 10)
curl -X POST http://localhost:8001/api/v1/generate/advanced \
  -H "Content-Type: application/json" \
  -d '{
    "count": 10,
    "difficulty": "medium",
    "topics": ["science", "history"],
    "enable_best_of_n": true,
    "n_multiplier": 3,
    "min_quality_score": 7.0
  }'
```

Response includes:
- 10 questions with AI scores
- Generation statistics
- Quality metadata

All questions start as "pending_review" - you need to review them!

---

## 📊 Monitoring Your Progress

### Goal 1: 50 Approved Questions (Minimum for Beta)

Check progress:
1. Go to **Statistics** page
2. Look at "Production-Ready Questions" count
3. Target: 50 approved

### Goal 2: 100 Approved Questions (Production Launch)

Check progress:
1. Statistics page shows progress bar
2. Target: 100 approved
3. Then move to mobile app development

### Goal 3: 500 Approved Questions (Fine-tuning Ready)

For future DPO fine-tuning:
- Need 500+ rated questions
- Mix of approved, rejected, needs revision
- Provides training data for Phase 3

---

## 🐛 Troubleshooting

### "No questions to review"

**Cause:** All questions are already reviewed
**Solution:** Import more questions or generate with advanced API

### "Database is empty" in quiz app

**Cause:** No approved questions in database
**Solution:**
1. Import rated questions (Step 2)
2. Or import + review some questions
3. Make sure at least some are "approved"

### Web UI shows 404

**Cause:** Template files not found
**Solution:** Check that `app/web/templates/` directory exists with all HTML files

### Import fails with JSON error

**Cause:** Invalid JSON format
**Solution:**
1. Check JSON is valid (use jsonlint.com)
2. Ensure it has "questions" array
3. Each question has required fields

### Advanced generation fails

**Cause:** OpenAI API key not set
**Solution:**
```bash
export OPENAI_API_KEY="your-key-here"
```

---

## 📈 Next Steps After Testing

Once you have 50-100 approved questions:

### 1. Start Mobile App Development

You have enough quality questions for:
- Alpha testing with friends/family
- Beta testing with small user group
- Real quiz gameplay testing

### 2. Continue Building Library

Goal: 500+ questions for all categories:
- Science
- History
- Geography
- Arts & Entertainment
- General Knowledge

### 3. Collect User Feedback

As people use the app:
- Track which questions work well
- Note which questions need revision
- Build preference data for fine-tuning

### 4. Prepare for Fine-tuning (Phase 3)

When you have 500+ rated questions:
- Export approved vs rejected pairs
- Create DPO training dataset
- Fine-tune your own model

---

## 🎯 Success Criteria

You're ready to move forward when:

- ✅ Web UI is accessible and working
- ✅ Can import questions from ChatGPT
- ✅ Can review and rate questions
- ✅ Quiz app only shows approved questions
- ✅ Have at least 50 approved questions
- ✅ Statistics page shows progress
- ✅ Quality scores are being tracked

---

## 💡 Tips for Efficient Review

### Review in Batches

1. Import 20-30 questions at once
2. Set aside 30 minutes
3. Review all at once
4. Takes ~1-2 min per question

### Use Keyboard Shortcuts (Future Enhancement)

- Enter = Approve
- R = Reject
- N = Needs Revision
- Skip = Space

### Be Honest with Ratings

- Don't inflate scores
- If a question is boring, mark it low
- This data helps improve future generation
- Aim for average 4.0+ for approved questions

---

## 📝 Files Created/Modified

### New Files:
- `app/web/routes.py` - Web UI endpoints
- `app/web/templates/base.html` - Base template
- `app/web/templates/home.html` - Question list
- `app/web/templates/import.html` - Import page
- `app/web/templates/review.html` - Review page
- `app/web/templates/stats.html` - Statistics
- `scripts/import_rated_questions.py` - Import script

### Modified Files:
- `packages/shared/quiz_shared/models/question.py` - Added review fields
- `packages/shared/quiz_shared/database/chroma_client.py` - Added review support
- `apps/question-generator/app/generation/storage.py` - Added new methods
- `apps/question-generator/app/main.py` - Added web routes
- `apps/quiz-agent/app/retrieval/question_retriever.py` - Filter for approved only

---

## 🎉 You're Ready!

The system is complete and tested. You can now:
1. Import your existing rated questions
2. Generate new questions with ChatGPT
3. Review and approve questions
4. Build your approved question library
5. Use only quality questions in your quiz app

Once you have 50-100 approved questions, you're ready to start building the mobile app!

Happy question reviewing! 🎯
