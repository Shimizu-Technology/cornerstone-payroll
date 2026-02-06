# AWS S3 Setup Guide

A guide for setting up AWS S3 file storage in web applications, covering both private (presigned URLs) and public bucket configurations.

---

## Table of Contents
1. [Overview & When to Use](#1-overview--when-to-use)
2. [AWS Account Setup](#2-aws-account-setup)
3. [Creating an S3 Bucket](#3-creating-an-s3-bucket)
4. [IAM User & Permissions](#4-iam-user--permissions)
5. [CORS Configuration](#5-cors-configuration)
6. [Private Bucket (Presigned URLs)](#6-private-bucket-presigned-urls)
7. [Public Bucket (Direct Access)](#7-public-bucket-direct-access)
8. [Backend Integration (Rails)](#8-backend-integration-rails)
9. [Backend Integration (FastAPI)](#9-backend-integration-fastapi)
10. [Frontend Upload Component](#10-frontend-upload-component)
11. [Environment Variables](#11-environment-variables)
12. [Testing & Debugging](#12-testing--debugging)
13. [Common Issues](#13-common-issues)
14. [Cost Considerations](#14-cost-considerations)

---

## 1. Overview & When to Use

### Private vs Public Buckets

| Approach | Use Case | Access Method |
|----------|----------|---------------|
| **Private** | Sensitive documents, user uploads, tax forms | Presigned URLs (time-limited) |
| **Public** | Marketing assets, logos, public images | Direct URL access |

### When to Use Private (Presigned URLs)
- User-uploaded documents (IDs, tax forms, contracts)
- Files that should only be accessible to authenticated users
- Temporary download links
- Audit trail requirements

### When to Use Public
- Static website assets (images, CSS, JS)
- Public marketing materials
- Content that should be crawlable/shareable
- CDN-backed content

---

## 2. AWS Account Setup

### First-Time AWS Setup:
1. Go to [aws.amazon.com](https://aws.amazon.com)
2. Click **Create an AWS Account**
3. Complete the registration (requires credit card)
4. Enable MFA on root account (Security best practice)

### AWS Free Tier:
- **S3**: 5 GB storage, 20,000 GET requests, 2,000 PUT requests/month (12 months)
- After free tier: ~$0.023/GB/month for standard storage

---

## 3. Creating an S3 Bucket

### Steps:
1. Go to **S3** in AWS Console
2. Click **Create bucket**
3. Configure:

| Setting | Private Bucket | Public Bucket |
|---------|---------------|---------------|
| Bucket name | `myapp-documents` | `myapp-assets` |
| Region | Choose closest to users | Choose closest to users |
| Object Ownership | ACLs disabled | ACLs disabled (or enabled for legacy) |
| Block Public Access | ✅ Block ALL | ❌ Uncheck "Block all" |
| Bucket Versioning | Optional (recommended) | Optional |
| Encryption | SSE-S3 (default) | SSE-S3 (default) |

### Naming Conventions:
```
{project}-{purpose}-{environment}

Examples:
- cornerstone-documents-prod
- myapp-uploads-staging
- acme-public-assets
```

### Region Selection:
| Region | Code | Best For |
|--------|------|----------|
| US East (N. Virginia) | us-east-1 | US East Coast, default |
| US West (Oregon) | us-west-2 | US West Coast |
| Asia Pacific (Sydney) | ap-southeast-2 | Australia, Guam, Pacific |
| EU (Ireland) | eu-west-1 | Europe |

---

## 4. IAM User & Permissions

### Creating an IAM User:

1. Go to **IAM** in AWS Console
2. Click **Users** → **Create user**
3. User name: `myapp-s3-api` (descriptive name)
4. Select **Programmatic access** (Access key)
5. Skip console access

### Attaching Permissions:

#### Option A: AWS Managed Policy (Quick but broad)
- Attach `AmazonS3FullAccess` 
- ⚠️ Not recommended for production (too permissive)

#### Option B: Custom Policy (Recommended)

Create a custom policy with least-privilege access:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "S3BucketAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::your-bucket-name",
                "arn:aws:s3:::your-bucket-name/*"
            ]
        }
    ]
}
```

For presigned URLs, also add:
```json
{
    "Action": [
        "s3:GetObject",
        "s3:PutObject"
    ],
    "Effect": "Allow",
    "Resource": "arn:aws:s3:::your-bucket-name/*"
}
```

### Getting Access Keys:

1. After creating user, go to **Security credentials** tab
2. Click **Create access key**
3. Choose **Application running outside AWS**
4. Download the CSV or copy:
   - Access Key ID: `AKIA...`
   - Secret Access Key: `wJalrXUtn...`

⚠️ **IMPORTANT**: 
- Store keys securely (password manager, not git!)
- You can only see the secret key once
- Rotate keys periodically
- Never commit keys to version control

---

## 5. CORS Configuration

CORS (Cross-Origin Resource Sharing) is required for browser-based uploads.

### For Private Bucket (Presigned POST):

Go to bucket → **Permissions** → **CORS configuration**:

```json
[
    {
        "AllowedHeaders": ["*"],
        "AllowedMethods": ["GET", "PUT", "POST", "DELETE", "HEAD"],
        "AllowedOrigins": [
            "http://localhost:5173",
            "http://localhost:3000",
            "https://your-production-domain.com"
        ],
        "ExposeHeaders": ["ETag"],
        "MaxAgeSeconds": 3000
    }
]
```

### For Public Bucket:

```json
[
    {
        "AllowedHeaders": ["*"],
        "AllowedMethods": ["GET", "PUT", "POST", "HEAD"],
        "AllowedOrigins": ["*"],
        "ExposeHeaders": ["ETag"],
        "MaxAgeSeconds": 3000
    }
]
```

### Common CORS Issues:
- **403 Forbidden**: Check bucket policy and CORS
- **No 'Access-Control-Allow-Origin'**: CORS not configured
- **Origin mismatch**: Add your exact origin (with/without trailing slash matters)

---

## 6. Private Bucket (Presigned URLs)

### How It Works:
1. **Upload**: Frontend requests presigned POST URL from backend
2. **Backend**: Generates time-limited URL with embedded credentials
3. **Frontend**: Uploads directly to S3 using presigned URL
4. **Download**: Backend generates presigned GET URL when needed

### Flow Diagram:
```
┌─────────┐         ┌─────────┐         ┌─────────┐
│ Browser │         │ Backend │         │   S3    │
└────┬────┘         └────┬────┘         └────┬────┘
     │                   │                   │
     │ 1. Request presign│                   │
     │──────────────────>│                   │
     │                   │                   │
     │ 2. Presigned URL  │                   │
     │<──────────────────│                   │
     │                   │                   │
     │ 3. Upload file directly               │
     │──────────────────────────────────────>│
     │                   │                   │
     │ 4. Success (201)  │                   │
     │<──────────────────────────────────────│
     │                   │                   │
     │ 5. Register doc   │                   │
     │──────────────────>│                   │
     │                   │ 6. Save to DB     │
     │                   │                   │
```

### Presigned POST vs PUT:

| Method | Use Case | Notes |
|--------|----------|-------|
| **Presigned POST** | Browser uploads with form fields | Supports conditions, file size limits |
| **Presigned PUT** | Simple direct upload | Simpler but less control |

---

## 7. Public Bucket (Direct Access)

### Bucket Policy for Public Read:

Go to bucket → **Permissions** → **Bucket policy**:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "PublicReadGetObject",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::your-bucket-name/*"
        }
    ]
}
```

### Public URL Format:
```
https://{bucket-name}.s3.{region}.amazonaws.com/{key}

Example:
https://myapp-assets.s3.us-east-1.amazonaws.com/images/logo.png
```

### Optional: CloudFront CDN

For better performance, add CloudFront:
1. Create CloudFront distribution
2. Set S3 bucket as origin
3. Use CloudFront URL instead of S3 URL
4. Benefits: Caching, HTTPS, custom domain

---

## 8. Backend Integration (Rails)

### Install AWS SDK:

```ruby
# Gemfile
gem 'aws-sdk-s3'
```

```bash
bundle install
```

### S3 Service Class:

```ruby
# app/services/s3_service.rb
class S3Service
  BUCKET_NAME = ENV.fetch("AWS_S3_BUCKET")
  REGION = ENV.fetch("AWS_REGION", "us-east-1")

  class << self
    def s3_client
      @s3_client ||= Aws::S3::Client.new(
        region: REGION,
        access_key_id: ENV.fetch("AWS_ACCESS_KEY_ID"),
        secret_access_key: ENV.fetch("AWS_SECRET_ACCESS_KEY")
      )
    end

    def s3_resource
      @s3_resource ||= Aws::S3::Resource.new(client: s3_client)
    end

    # Generate presigned POST for browser upload
    def generate_presigned_post(key, content_type, expires_in: 3600)
      bucket = s3_resource.bucket(BUCKET_NAME)
      
      bucket.presigned_post(
        key: key,
        acl: "private",
        content_type: content_type,
        success_action_status: "201",
        expires: Time.now + expires_in
      )
    end

    # Generate presigned GET URL for download
    def generate_presigned_url(key, expires_in: 3600)
      presigner = Aws::S3::Presigner.new(client: s3_client)
      presigner.presigned_url(
        :get_object,
        bucket: BUCKET_NAME,
        key: key,
        expires_in: expires_in
      )
    end

    # Delete an object
    def delete_object(key)
      s3_resource.bucket(BUCKET_NAME).object(key).delete
      true
    rescue Aws::S3::Errors::NoSuchKey
      true # Already deleted
    rescue Aws::S3::Errors::ServiceError => e
      Rails.logger.error "S3 delete error: #{e.message}"
      false
    end

    # Direct upload from backend (for server-side processing)
    def upload_file(key, file_path, content_type: nil)
      obj = s3_resource.bucket(BUCKET_NAME).object(key)
      obj.upload_file(file_path, content_type: content_type)
      obj.public_url
    end
  end
end
```

### Controller for Presigned URLs:

```ruby
# app/controllers/api/v1/documents_controller.rb
module Api
  module V1
    class DocumentsController < BaseController
      before_action :authenticate_user!

      # POST /api/v1/documents/presign
      def presign
        filename = params[:filename]
        content_type = params[:content_type] || "application/octet-stream"
        
        # Generate unique key
        s3_key = "uploads/#{current_user.id}/#{Time.current.strftime('%Y%m%d%H%M%S')}_#{filename}"

        presigned = S3Service.generate_presigned_post(s3_key, content_type)

        render json: {
          upload_url: presigned.url,
          fields: presigned.fields,
          s3_key: s3_key
        }
      end

      # POST /api/v1/documents
      def create
        document = Document.new(document_params)
        document.uploaded_by = current_user

        if document.save
          render json: { document: document }, status: :created
        else
          render json: { errors: document.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/documents/:id/download
      def download
        document = Document.find(params[:id])
        url = S3Service.generate_presigned_url(document.s3_key)
        
        render json: { download_url: url }
      end

      private

      def document_params
        params.require(:document).permit(:filename, :s3_key, :content_type, :file_size, :document_type)
      end
    end
  end
end
```

---

## 9. Backend Integration (FastAPI)

### Install boto3:

```bash
pip install boto3
```

### S3 Service Class:

```python
# app/services/s3_service.py
import boto3
from botocore.config import Config
import os
import uuid

class S3Service:
    def __init__(self):
        self.bucket_name = os.environ.get("AWS_S3_BUCKET")
        self.region = os.environ.get("AWS_REGION", "us-east-1")
        
        self.client = boto3.client(
            "s3",
            region_name=self.region,
            aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID"),
            aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY"),
            config=Config(signature_version="s3v4")
        )

    def generate_presigned_post(self, key: str, content_type: str, expires_in: int = 3600):
        """Generate presigned POST for browser upload."""
        return self.client.generate_presigned_post(
            Bucket=self.bucket_name,
            Key=key,
            Fields={"Content-Type": content_type},
            Conditions=[
                {"Content-Type": content_type},
                ["content-length-range", 1, 50 * 1024 * 1024]  # Max 50MB
            ],
            ExpiresIn=expires_in
        )

    def generate_presigned_url(self, key: str, expires_in: int = 3600):
        """Generate presigned GET URL for download."""
        return self.client.generate_presigned_url(
            "get_object",
            Params={"Bucket": self.bucket_name, "Key": key},
            ExpiresIn=expires_in
        )

    def delete_object(self, key: str):
        """Delete an object from S3."""
        try:
            self.client.delete_object(Bucket=self.bucket_name, Key=key)
            return True
        except Exception as e:
            print(f"Error deleting {key}: {e}")
            return False

    def upload_file(self, file_content: bytes, key: str, content_type: str):
        """Upload file directly from backend."""
        self.client.put_object(
            Bucket=self.bucket_name,
            Key=key,
            Body=file_content,
            ContentType=content_type
        )
        return f"https://{self.bucket_name}.s3.{self.region}.amazonaws.com/{key}"


# Singleton
s3_service = S3Service()
```

### FastAPI Routes:

```python
# app/api/documents.py
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel
import uuid
from datetime import datetime

from ..services.s3_service import s3_service
from ..database import get_db

router = APIRouter()

class PresignRequest(BaseModel):
    filename: str
    content_type: str

@router.post("/presign")
async def presign_upload(request: PresignRequest):
    """Get presigned URL for uploading a file."""
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    s3_key = f"uploads/{timestamp}_{uuid.uuid4().hex[:8]}_{request.filename}"
    
    presigned = s3_service.generate_presigned_post(s3_key, request.content_type)
    
    return {
        "upload_url": presigned["url"],
        "fields": presigned["fields"],
        "s3_key": s3_key
    }

@router.get("/{document_id}/download")
async def download_document(document_id: str, db = Depends(get_db)):
    """Get presigned download URL."""
    document = db.query(Document).filter(Document.id == document_id).first()
    if not document:
        raise HTTPException(status_code=404, detail="Document not found")
    
    url = s3_service.generate_presigned_url(document.s3_key)
    return {"download_url": url}
```

---

## 10. Frontend Upload Component

### React Component (TypeScript):

```tsx
// components/FileUpload.tsx
import { useState, useCallback } from 'react'
import { api } from '../lib/api'

interface FileUploadProps {
  onUploadComplete: (s3Key: string, filename: string) => void
  acceptedTypes?: string
  maxSizeMB?: number
}

export default function FileUpload({ 
  onUploadComplete, 
  acceptedTypes = "*",
  maxSizeMB = 25 
}: FileUploadProps) {
  const [uploading, setUploading] = useState(false)
  const [progress, setProgress] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [isDragging, setIsDragging] = useState(false)

  const uploadFile = async (file: File) => {
    // Validate file size
    if (file.size > maxSizeMB * 1024 * 1024) {
      setError(`File too large. Maximum size is ${maxSizeMB}MB.`)
      return
    }

    setError(null)
    setUploading(true)
    setProgress('Getting upload URL...')

    try {
      // 1. Get presigned URL from backend
      const presignResult = await api.presignUpload(file.name, file.type || 'application/octet-stream')
      
      if (!presignResult.data) {
        throw new Error('Failed to get upload URL')
      }

      const { upload_url, fields, s3_key } = presignResult.data

      // 2. Upload to S3 using presigned POST
      setProgress('Uploading...')
      
      const formData = new FormData()
      Object.entries(fields).forEach(([key, value]) => {
        formData.append(key, value as string)
      })
      formData.append('file', file) // File must be last!

      const uploadResponse = await fetch(upload_url, {
        method: 'POST',
        body: formData,
      })

      if (!uploadResponse.ok) {
        throw new Error(`Upload failed: ${uploadResponse.status}`)
      }

      // 3. Success!
      setProgress('Complete!')
      onUploadComplete(s3_key, file.name)

      setTimeout(() => {
        setProgress(null)
        setUploading(false)
      }, 1000)

    } catch (err) {
      setError(err instanceof Error ? err.message : 'Upload failed')
      setProgress(null)
      setUploading(false)
    }
  }

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault()
    setIsDragging(false)
    
    const files = Array.from(e.dataTransfer.files)
    if (files.length > 0) {
      uploadFile(files[0])
    }
  }, [])

  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault()
    setIsDragging(true)
  }

  const handleDragLeave = (e: React.DragEvent) => {
    e.preventDefault()
    setIsDragging(false)
  }

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    if (e.target.files && e.target.files.length > 0) {
      uploadFile(e.target.files[0])
    }
  }

  return (
    <div
      onDrop={handleDrop}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      className={`
        border-2 border-dashed rounded-lg p-6 text-center transition-colors
        ${isDragging ? 'border-blue-500 bg-blue-50' : 'border-gray-300'}
        ${uploading ? 'opacity-50 pointer-events-none' : ''}
      `}
    >
      {uploading ? (
        <div className="flex flex-col items-center">
          <div className="animate-spin w-8 h-8 border-4 border-blue-500 border-t-transparent rounded-full mb-2" />
          <p className="text-sm text-gray-600">{progress}</p>
        </div>
      ) : (
        <>
          <svg className="mx-auto h-12 w-12 text-gray-400 mb-3" stroke="currentColor" fill="none" viewBox="0 0 48 48">
            <path d="M28 8H12a4 4 0 00-4 4v20m32-12v8m0 0v8a4 4 0 01-4 4H12a4 4 0 01-4-4v-4m32-4l-3.172-3.172a4 4 0 00-5.656 0L28 28M8 32l9.172-9.172a4 4 0 015.656 0L28 28m0 0l4 4m4-4V8m-12 8h.02" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          
          <label className="cursor-pointer">
            <span className="text-blue-600 hover:text-blue-700 font-medium">Upload a file</span>
            <input
              type="file"
              className="hidden"
              accept={acceptedTypes}
              onChange={handleFileSelect}
            />
          </label>
          <span className="text-gray-500"> or drag and drop</span>
          
          <p className="text-xs text-gray-400 mt-2">
            Up to {maxSizeMB}MB
          </p>
        </>
      )}
      
      {error && (
        <p className="text-red-600 text-sm mt-2">{error}</p>
      )}
    </div>
  )
}
```

### API Client Functions:

```typescript
// lib/api.ts
export const api = {
  presignUpload: (filename: string, contentType: string) =>
    fetchApi<{ upload_url: string; fields: Record<string, string>; s3_key: string }>(
      '/api/v1/documents/presign',
      {
        method: 'POST',
        body: JSON.stringify({ filename, content_type: contentType }),
      }
    ),

  registerDocument: (data: {
    filename: string;
    s3_key: string;
    content_type: string;
    file_size: number;
  }) =>
    fetchApi('/api/v1/documents', {
      method: 'POST',
      body: JSON.stringify({ document: data }),
    }),

  getDownloadUrl: (documentId: number) =>
    fetchApi<{ download_url: string }>(`/api/v1/documents/${documentId}/download`),
}
```

---

## 11. Environment Variables

### Development (.env):

```bash
# AWS S3 Configuration
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=wJalrXUtn...
AWS_S3_BUCKET=myapp-documents-dev
AWS_REGION=us-east-1
```

### Production (Render/Heroku/etc):

Set these as environment variables in your hosting platform:

| Variable | Example | Notes |
|----------|---------|-------|
| `AWS_ACCESS_KEY_ID` | `AKIAIOSFODNN7EXAMPLE` | From IAM user |
| `AWS_SECRET_ACCESS_KEY` | `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` | Keep secret! |
| `AWS_S3_BUCKET` | `myapp-documents-prod` | Your bucket name |
| `AWS_REGION` | `ap-southeast-2` | Bucket region |

### Multiple Buckets (Optional):

```bash
# If you have separate buckets for different purposes
AWS_S3_BUCKET_DOCUMENTS=myapp-documents
AWS_S3_BUCKET_ASSETS=myapp-public-assets
```

---

## 12. Testing & Debugging

### Test Upload Locally:

```ruby
# Rails console
S3Service.generate_presigned_post("test/hello.txt", "text/plain")
# Should return: #<Aws::S3::PresignedPost ...>
```

```python
# Python
from app.services.s3_service import s3_service
s3_service.generate_presigned_post("test/hello.txt", "text/plain")
# Should return: {'url': 'https://...', 'fields': {...}}
```

### Check Browser Console:

Successful upload should show:
```
POST https://bucket.s3.region.amazonaws.com/ 201 (Created)
```

### AWS CLI Testing:

```bash
# Install AWS CLI
brew install awscli  # macOS

# Configure
aws configure
# Enter your access key, secret key, region

# List bucket contents
aws s3 ls s3://your-bucket-name/

# Upload a test file
aws s3 cp test.txt s3://your-bucket-name/test.txt

# Download a file
aws s3 cp s3://your-bucket-name/test.txt ./downloaded.txt
```

### Check S3 Console:

1. Go to S3 in AWS Console
2. Click your bucket
3. Verify files are appearing after upload

---

## 13. Common Issues

### 403 Forbidden on Upload

**Causes:**
- CORS not configured
- IAM permissions incorrect
- Bucket policy blocking
- Wrong region in presigned URL

**Solutions:**
1. Check CORS configuration (Section 5)
2. Verify IAM policy includes `s3:PutObject`
3. Ensure bucket isn't blocking public access (for presigned, this is OK)

### SignatureDoesNotMatch

**Causes:**
- Wrong secret key
- Clock skew between client and server
- Incorrect region

**Solutions:**
1. Verify AWS credentials
2. Check region matches bucket region
3. Ensure system clock is accurate

### Access Denied on Download

**Causes:**
- Presigned URL expired
- Object doesn't exist
- IAM missing `s3:GetObject`

**Solutions:**
1. Generate new presigned URL
2. Verify object exists in S3
3. Check IAM permissions

### CORS Error in Browser

**Causes:**
- CORS configuration missing
- Origin not in allowed list
- Preflight request failing

**Solutions:**
1. Add CORS configuration (Section 5)
2. Include your exact origin (no trailing slash)
3. Include all methods: GET, PUT, POST, DELETE, HEAD

### File Appears But Download Fails

**Causes:**
- Object exists but key mismatch
- Presigned URL uses wrong key

**Solutions:**
1. Log the exact s3_key being saved
2. Verify key in database matches S3

---

## 14. Cost Considerations

### S3 Pricing (us-east-1):

| Component | Price |
|-----------|-------|
| Storage (Standard) | $0.023/GB/month |
| PUT/POST requests | $0.005/1,000 requests |
| GET requests | $0.0004/1,000 requests |
| Data transfer OUT | $0.09/GB (first 10TB) |

### Example Monthly Costs:

| Usage | Approximate Cost |
|-------|------------------|
| 10 GB storage, 1,000 uploads, 5,000 downloads | ~$0.50 |
| 100 GB storage, 10,000 uploads, 50,000 downloads | ~$3.50 |
| 1 TB storage, 100,000 uploads, 500,000 downloads | ~$30 |

### Cost Optimization:

1. **Lifecycle Rules**: Move old files to Glacier
2. **CloudFront**: Reduce data transfer costs
3. **Intelligent Tiering**: Auto-optimize storage class
4. **Delete unused files**: Clean up regularly

---

## Quick Reference

### Checklist for New Project:

- [ ] Create S3 bucket (private or public)
- [ ] Create IAM user with S3 permissions
- [ ] Download access keys
- [ ] Configure CORS on bucket
- [ ] Add bucket policy (if public)
- [ ] Set environment variables
- [ ] Implement backend service (Rails/FastAPI)
- [ ] Implement frontend upload component
- [ ] Test upload flow end-to-end

### Key Endpoints:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/documents/presign` | POST | Get presigned upload URL |
| `/documents` | POST | Register uploaded document |
| `/documents/:id/download` | GET | Get presigned download URL |
| `/documents/:id` | DELETE | Delete document |

### S3 URL Formats:

```
# Virtual-hosted style (recommended)
https://{bucket}.s3.{region}.amazonaws.com/{key}

# Path style (legacy)
https://s3.{region}.amazonaws.com/{bucket}/{key}

# Presigned URL (temporary)
https://{bucket}.s3.{region}.amazonaws.com/{key}?X-Amz-Algorithm=...&X-Amz-Signature=...
```
